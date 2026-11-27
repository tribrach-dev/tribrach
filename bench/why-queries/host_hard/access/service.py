"""The access service: request handling around the decision rules."""
import json

from . import audit, decision, metrics
from .alerts import Throttle
from .model import Tap
from .policy import Policy
from .policy_data import DEFAULT_POLICY


class RequestError(ValueError):
    pass


REQUIRED = {"now": ("day", "hour"), "person": ("id", "kind", "badge"), "door": ("id", "zone")}


def validate(raw):
    if not isinstance(raw, dict):
        raise RequestError("tap must be an object")
    for section, keys in REQUIRED.items():
        part = raw.get(section)
        if not isinstance(part, dict):
            raise RequestError(f"missing {section}")
        for k in keys:
            if k not in part:
                raise RequestError(f"missing {section}.{k}")
    return raw


class AccessService:
    def __init__(self, policy, log=None):
        self.policy = policy
        self.audit = log if log is not None else audit.AuditLog()
        self.metrics = metrics.Counters()
        self.throttle = Throttle(policy.alert_cooldown_seconds)
        self._clock_seconds = 0

    @classmethod
    def from_default_policy(cls):
        return cls(Policy.parse(DEFAULT_POLICY))

    def reload(self, policy_text):
        """Swap in a new policy; keep the old one if the new text doesn't parse."""
        self.policy = Policy.parse(policy_text)
        self.throttle = Throttle(self.policy.alert_cooldown_seconds)
        self.metrics.inc("policy.reload")

    def handle_tap(self, raw):
        tap = Tap.from_json(validate(raw))
        result = decision.evaluate(tap, self.policy)
        self._clock_seconds += 1
        self.metrics.inc("tap")
        self.metrics.inc("tap.open" if result.open else "tap.denied")
        self.audit.record(tap, result)
        return result

    def handle_http(self, body):
        """Minimal HTTP-style wrapper used by the door controllers."""
        try:
            raw = json.loads(body)
            result = self.handle_tap(raw)
        except (RequestError, json.JSONDecodeError) as e:
            self.metrics.inc("tap.bad_request")
            return 400, json.dumps({"error": str(e)})
        sent = [a for a in result.alerts if self.throttle.allow(a, self._clock_seconds)]
        return 200, json.dumps({
            "door": result.door,
            "unlock": result.open,
            "second_factor": result.two_factor,
            "alerts": [a.reason for a in sent],
        })
