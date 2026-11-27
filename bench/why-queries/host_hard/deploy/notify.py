"""Chat messages about gate verdicts (no effect on the verdict)."""
from . import settings, slo


class Notifier:
    def __init__(self, send=None):
        self.sent = []
        self._send = send

    def _post(self, channel, text):
        self.sent.append((channel, text))
        if self._send:
            self._send(channel, text)

    def verdict(self, req, v):
        ch = req.change
        if v.blockers:
            text = f"{ch.id} ({ch.service}) blocked: " + "; ".join(v.blockers)
        else:
            how = "canary" if v.canary and not v.deploy else "full deploy"
            text = f"{ch.id} ({ch.service}) cleared for {how}"
        self._post(settings.CHAT_CHANNEL, text)
        if ch.migration and req.service.tier in settings.MIGRATION_SRE_TIERS:
            self._post("#sre", f"migration in {ch.service}: {text}")
        budget = slo.Budget(ch.service, req.service.error_budget_pct)
        if budget.burn_alert:
            self._post(f"#{ch.service}-oncall", slo.describe(budget))

    def digest(self, verdicts):
        shipped = sum(1 for v in verdicts if v.deploy or v.canary)
        return f"{shipped}/{len(verdicts)} changes shipped today"
