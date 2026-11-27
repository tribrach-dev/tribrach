"""The plan for one tick: which valves to open and which alerts to send."""
from dataclasses import dataclass, field


@dataclass
class Plan:
    water: list = field(default_factory=list)
    alerts: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    def decisions(self):
        return sorted([f"water {z}" for z in self.water] + [f"alert {z}" for z in self.alerts])

    def note(self, zone, text):
        self.notes.append(f"{zone}: {text}")


def batches(zones, max_open):
    """Split zones into groups that can run at the same time."""
    return [zones[i:i + max_open] for i in range(0, len(zones), max_open)]


def runtime_minutes(plan, kinds, valves):
    total = 0
    for group in batches(plan.water, valves.max_open_at_once):
        total += max(valves.run_minutes.get(kinds[z], 10) for z in group)
        total += valves.flush_seconds / 60
    return round(total, 1)
