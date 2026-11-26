"""A small in-memory log of recent ticks, for the status page."""
from collections import deque


class History:
    def __init__(self, keep=48):
        self._ticks = deque(maxlen=keep)

    def record(self, when, plan):
        self._ticks.append((when, list(plan.water), list(plan.alerts), list(plan.notes)))

    def last_watered(self, zone):
        for when, water, _, _ in reversed(self._ticks):
            if zone in water:
                return when
        return None

    def alert_count(self, zone):
        return sum(1 for _, _, alerts, _ in self._ticks if zone in alerts)

    def summary(self):
        lines = []
        for when, water, alerts, _ in self._ticks:
            parts = []
            if water:
                parts.append("watered " + ", ".join(water))
            if alerts:
                parts.append("alerts " + ", ".join(alerts))
            lines.append(f"{when}: " + ("; ".join(parts) if parts else "nothing"))
        return "\n".join(lines)
