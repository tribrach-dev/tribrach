"""Typed views of one badge tap."""
from dataclasses import dataclass, field
from typing import Optional

EMPLOYEE, CONTRACTOR, VISITOR = "employee", "contractor", "visitor"
NO_ROLE = "none"


@dataclass(frozen=True)
class Escort:
    id: str
    role: str
    on_site: bool
    training: frozenset

    @classmethod
    def from_json(cls, j):
        if not j:
            return None
        return cls(id=j["id"], role=j.get("role", NO_ROLE), on_site=bool(j.get("on_site")),
                   training=frozenset(j.get("training", [])))


@dataclass(frozen=True)
class Person:
    id: str
    kind: str
    role: str
    badge: str
    contract_days_left: Optional[int]
    training: frozenset
    responder: bool
    escort: Optional[Escort]

    @classmethod
    def from_json(cls, j):
        days = j.get("contract_days_left")
        return cls(id=j["id"], kind=j["kind"], role=j.get("role", NO_ROLE), badge=j["badge"],
                   contract_days_left=None if days is None else int(days),
                   training=frozenset(j.get("training", [])),
                   responder=bool(j.get("responder", False)),
                   escort=Escort.from_json(j.get("escort")))

    @property
    def has_role(self):
        return self.role != NO_ROLE


@dataclass(frozen=True)
class Door:
    id: str
    zone: str
    after_hours: bool = False
    egress: bool = False

    @classmethod
    def from_json(cls, j):
        return cls(id=j["id"], zone=j["zone"], after_hours=bool(j.get("after_hours")),
                   egress=bool(j.get("egress")))


@dataclass(frozen=True)
class Now:
    day: str
    hour: int
    holiday: bool = False

    @classmethod
    def from_json(cls, j):
        return cls(day=j["day"], hour=int(j["hour"]), holiday=bool(j.get("holiday")))


@dataclass(frozen=True)
class Site:
    lockdown: bool = False
    fire_alarm: bool = False

    @classmethod
    def from_json(cls, j):
        return cls(lockdown=bool(j.get("lockdown")), fire_alarm=bool(j.get("fire_alarm")))


@dataclass
class Tap:
    now: Now
    site: Site
    person: Person
    door: Door
    meta: dict = field(default_factory=dict)

    @classmethod
    def from_json(cls, j):
        return cls(now=Now.from_json(j["now"]), site=Site.from_json(j.get("site", {})),
                   person=Person.from_json(j["person"]), door=Door.from_json(j["door"]),
                   meta=dict(j.get("meta", {})))
