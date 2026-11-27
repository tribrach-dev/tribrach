"""Runs one hourly tick: parse readings, decide each zone, record the plan."""
from . import config, readings, rules
from .history import History
from .plan import Plan, runtime_minutes


class Controller:
    def __init__(self, settings, history=None, dry_run=False):
        self.settings = settings
        self.history = history or History()
        self.dry_run = dry_run

    @classmethod
    def default(cls):
        return cls(config.load())

    def tick(self, inp):
        cond, zones = readings.parse(inp)
        plan = Plan()
        for zone in zones:
            rules.decide_zone(zone, cond, self.settings, plan)
        self.history.record(readings.describe(cond), plan)
        return plan

    def status(self, inp):
        """A human-readable status line, for the app's home screen."""
        cond, zones = readings.parse(inp)
        plan = self.tick(inp)
        kinds = {z.name: z.kind for z in zones}
        minutes = runtime_minutes(plan, kinds, self.settings.valves)
        head = f"{self.settings.site_name} at {readings.describe(cond)}"
        if not plan.water:
            return head + ": no watering"
        return head + f": watering {', '.join(plan.water)} (~{minutes} min)"
