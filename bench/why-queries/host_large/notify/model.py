"""Typed views of the input."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Prefs:
    quiet_start: int
    quiet_end: int
    channels: frozenset
    sms_verified: bool

    @classmethod
    def from_json(cls, j):
        return cls(quiet_start=int(j["quiet_start"]), quiet_end=int(j["quiet_end"]),
                   channels=frozenset(j.get("channels", [])),
                   sms_verified=bool(j.get("sms_verified", False)))


@dataclass(frozen=True)
class Event:
    kind: str
    priority: str
    title: str = ""

    @classmethod
    def from_json(cls, j):
        return cls(kind=j["kind"], priority=j.get("priority", "normal"), title=j.get("title", ""))


@dataclass(frozen=True)
class Context:
    hour: int
    sent_last_hour: int

    @classmethod
    def from_json(cls, j):
        return cls(hour=int(j["hour"]) % 24, sent_last_hour=int(j.get("sent_last_hour", 0)))
