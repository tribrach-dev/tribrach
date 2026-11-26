"""The deploy gate: decides how a change may ship."""
from dataclasses import dataclass, field

from . import approvals, audit, checks, notify, slo, window
from .model import Request


@dataclass
class Verdict:
    service: str
    deploy: bool = False
    canary: bool = False
    page: bool = False
    blockers: list = field(default_factory=list)

    def decisions(self):
        out = []
        if self.deploy:
            out.append(f"deploy {self.service}")
        if self.canary:
            out.append(f"canary {self.service}")
        if self.page:
            out.append(f"page {self.service}")
        return sorted(out)


def blockers(req):
    ch, svc = req.change, req.service
    out = []
    if not checks.all_green(req.checks, svc.tier):
        out.append("checks: " + ", ".join(checks.failing(req.checks, svc.tier)))
    if not approvals.enough_for_risk(req.approvals, ch):
        out.append("approvals: " + approvals.summary(req.approvals, ch))
    sre_ok = approvals.sre_approved(req.approvals, ch)
    if ch.migration and not sre_ok:
        out.append("migration needs an sre approval")
    if svc.tier == 1 and not approvals.owner_approved(req.approvals, ch):
        out.append("tier 1 needs an owner approval")
    if not window.may_ship_now(req, sre_ok):
        out.append("outside the deploy window")
    return out


def rollout(req, verdict):
    ch, svc = req.change, req.service
    budget = slo.Budget(ch.service, svc.error_budget_pct)
    if svc.canary and (ch.risk == "high" or not budget.healthy):
        verdict.canary = True
    if budget.healthy and (ch.risk != "high" or not svc.canary):
        verdict.deploy = True
    if ch.hotfix or (ch.migration and svc.tier == 1):
        verdict.page = True


class Gate:
    def __init__(self, notifier=None, log=None):
        self.notifier = notifier or notify.Notifier()
        self.log = log if log is not None else audit.Log()

    @classmethod
    def default(cls):
        return cls()

    def evaluate(self, raw):
        req = Request.from_json(raw)
        v = Verdict(req.change.service)
        v.blockers = blockers(req)
        if not v.blockers:
            rollout(req, v)
        self.log.add(req, v)
        self.notifier.verdict(req, v)
        return v
