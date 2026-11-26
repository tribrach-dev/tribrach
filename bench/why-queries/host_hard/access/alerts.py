"""Taps security should hear about."""
from dataclasses import dataclass

from . import contracts, credentials
from .model import VISITOR


@dataclass(frozen=True)
class Alert:
    person: str
    door: str
    reason: str

    def decision(self):
        return f"alert {self.person} {self.door}"


def alerts_for(tap):
    p, d = tap.person, tap.door
    out = []
    if credentials.badge_flagged(p):
        out.append(Alert(p.id, d.id, f"badge {p.badge}"))
    if contracts.has_ended(p):
        out.append(Alert(p.id, d.id, "contract ended"))
    if p.kind == VISITOR and not credentials.escort_present(p):
        out.append(Alert(p.id, d.id, "visitor without escort"))
    return out


class Throttle:
    """Drop repeat alerts for the same person and door within the cooldown."""

    def __init__(self, cooldown_seconds):
        self.cooldown = cooldown_seconds
        self._last = {}

    def allow(self, alert, at_seconds):
        key = (alert.person, alert.door)
        last = self._last.get(key)
        if last is not None and at_seconds - last < self.cooldown:
            return False
        self._last[key] = at_seconds
        return True
