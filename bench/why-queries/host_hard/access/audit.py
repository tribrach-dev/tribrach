"""Append-only audit trail of taps."""
from collections import deque

from . import clock


class AuditLog:
    def __init__(self, keep=10_000):
        self._rows = deque(maxlen=keep)

    def record(self, tap, result):
        self._rows.append({
            "when": clock.describe(tap.now),
            "person": tap.person.id,
            "kind": tap.person.kind,
            "door": tap.door.id,
            "zone": tap.door.zone,
            "open": result.open,
            "two_factor": result.two_factor,
            "reasons": list(result.reasons),
        })

    def rows(self, person=None, door=None):
        for r in self._rows:
            if person and r["person"] != person:
                continue
            if door and r["door"] != door:
                continue
            yield r

    def denied(self):
        return [r for r in self._rows if not r["open"] and not r["two_factor"]]

    def to_csv(self):
        cols = ["when", "person", "kind", "door", "zone", "open", "two_factor"]
        lines = [",".join(cols)]
        for r in self._rows:
            lines.append(",".join(str(r[c]) for c in cols))
        return "\n".join(lines)
