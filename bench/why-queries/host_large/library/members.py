"""Member records as the desk sees them."""
from dataclasses import dataclass

from . import policy

ACTIVE = "active"


@dataclass(frozen=True)
class Member:
    id: str
    age: int
    status: str
    fines_cents: int
    loans: int
    tier: str

    @classmethod
    def from_json(cls, j):
        return cls(id=j["id"], age=int(j["age"]), status=j["status"],
                   fines_cents=int(j["fines_cents"]), loans=int(j["loans"]),
                   tier=j.get("tier", "standard"))


def loan_limit(member):
    limits = policy.get("loan_limits")
    return limits.get(member.tier, limits["standard"])


def blocked_reasons(member):
    """Why a member may not borrow anything today (empty list if they may)."""
    reasons = []
    if member.status != ACTIVE:
        reasons.append(f"membership {member.status}")
    if member.fines_cents >= policy.get("fines.block_at_cents"):
        reasons.append("fines")
    if member.loans >= loan_limit(member):
        reasons.append("at loan limit")
    return reasons


def fines_display(member):
    waive = policy.get("fines.waive_below_cents", 0)
    if member.fines_cents < waive:
        return "no fines"
    return f"${member.fines_cents / 100:.2f} owed"
