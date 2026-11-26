"""Typed views of the gate's input."""
from dataclasses import dataclass, field

from . import checks


@dataclass(frozen=True)
class Change:
    id: str
    service: str
    author: str
    risk: str
    migration: bool = False
    hotfix: bool = False

    @classmethod
    def from_json(cls, j):
        return cls(id=j.get("id", "?"), service=j["service"], author=j["author"], risk=j["risk"],
                   migration=bool(j.get("migration")), hotfix=bool(j.get("hotfix")))


@dataclass(frozen=True)
class Service:
    tier: int
    error_budget_pct: int
    canary: bool

    @classmethod
    def from_json(cls, j):
        return cls(tier=int(j["tier"]), error_budget_pct=int(j["error_budget_pct"]),
                   canary=bool(j.get("canary")))


@dataclass(frozen=True)
class Approval:
    by: str
    role: str


@dataclass(frozen=True)
class Calendar:
    day: str
    hour: int
    freeze: bool = False


@dataclass
class Request:
    change: Change
    service: Service
    checks: dict
    approvals: list
    calendar: Calendar
    oncall_acked: bool
    extra: dict = field(default_factory=dict)

    @classmethod
    def from_json(cls, j):
        cal = j["calendar"]
        return cls(change=Change.from_json(j["change"]), service=Service.from_json(j["service"]),
                   checks=checks.normalize(j.get("checks", {})),
                   approvals=[Approval(a["by"], a["role"]) for a in j.get("approvals", [])],
                   calendar=Calendar(cal["day"], int(cal["hour"]), bool(cal.get("freeze"))),
                   oncall_acked=bool(j.get("oncall", {}).get("acked")))
