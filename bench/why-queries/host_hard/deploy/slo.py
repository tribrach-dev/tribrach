"""Error budgets."""
from dataclasses import dataclass

# A service with at least this share of its error budget left may take a full
# deploy; below it, changes go to the canary first.
HEALTHY_BUDGET_PCT = 20

# Page the owning team when the budget burns below this share (monitoring
# only; the gate doesn't use it).
BURN_ALERT_PCT = 10


@dataclass(frozen=True)
class Budget:
    service: str
    remaining_pct: int

    @property
    def healthy(self):
        return self.remaining_pct >= HEALTHY_BUDGET_PCT

    @property
    def burn_alert(self):
        return self.remaining_pct < BURN_ALERT_PCT


def describe(b):
    state = "healthy" if b.healthy else "low"
    return f"{b.service}: {b.remaining_pct}% budget left ({state})"
