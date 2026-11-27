"""Puts the rules together for one tap."""
from dataclasses import dataclass, field

from . import alerts, clock, contracts, credentials, hours, training


@dataclass
class Decision:
    door: str
    open: bool = False
    two_factor: bool = False
    alerts: list = field(default_factory=list)
    notices: list = field(default_factory=list)
    reasons: list = field(default_factory=list)

    def decisions(self):
        out = []
        if self.open:
            out.append(f"open {self.door}")
        if self.two_factor:
            out.append(f"two_factor {self.door}")
        out += [a.decision() for a in self.alerts]
        out += [f"expiry_notice {p}" for p in self.notices]
        return sorted(set(out))


def may_pass(tap, policy):
    """Credential, zone, training, hours and lockdown, ignoring the second factor."""
    p, d, now, site = tap.person, tap.door, tap.now, tap.site
    if not credentials.credential_valid(p):
        return False, "credential"
    if site.lockdown:
        return (True, "responder") if p.responder else (False, "lockdown")
    if not training.cleared(p, d.zone, policy):
        return False, "zone or training"
    if not hours.hours_ok(p, d, now, policy):
        return False, "hours"
    return True, "ok"


def evaluate(tap, policy):
    d = tap.door
    out = Decision(d.id)
    ok, why = may_pass(tap, policy)
    out.reasons.append(why)
    if ok:
        if d.zone in policy.second_factor_zones and not clock.is_business_hours(tap.now, policy):
            out.two_factor = True
        else:
            out.open = True
        if contracts.is_ending_soon(tap.person, policy):
            out.notices.append(tap.person.id)
    if tap.site.fire_alarm and d.egress:
        out.open = True
        out.reasons.append("fire egress")
    out.alerts = alerts.alerts_for(tap)
    return out
