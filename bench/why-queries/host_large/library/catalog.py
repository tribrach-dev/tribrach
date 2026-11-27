"""Items and their circulation status."""
from dataclasses import dataclass
from typing import Optional

ON_SHELF = "on_shelf"
ON_HOLD = "on_hold"
OUT = "out"


@dataclass(frozen=True)
class Item:
    id: str
    kind: str
    rating: str
    status: str
    held_for: Optional[str]

    @classmethod
    def from_json(cls, j):
        return cls(id=j["id"], kind=j["kind"], rating=j.get("rating", "all"),
                   status=j["status"], held_for=j.get("held_for"))

    @property
    def circulates(self):
        return self.kind != "reference"


def can_take(item, member_id):
    """Can this member take the item from the desk right now?"""
    if item.status == ON_SHELF:
        return item.circulates
    if item.status == ON_HOLD:
        return item.held_for == member_id
    return False


def due_days(item):
    from . import policy
    return policy.get("loan_days").get(item.kind, 14)
