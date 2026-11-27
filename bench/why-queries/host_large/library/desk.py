"""The checkout desk: decides which requested items a member may take home."""
from dataclasses import dataclass, field

from . import catalog, members, ratings
from .receipts import receipt


@dataclass
class Checkout:
    member_id: str
    lent: list = field(default_factory=list)
    refused: dict = field(default_factory=dict)

    def decisions(self):
        return sorted(f"lend {self.member_id} {i}" for i in self.lent)


class Desk:
    def __init__(self, log=None):
        self.log = log if log is not None else []

    @classmethod
    def default(cls):
        return cls()

    def checkout(self, inp):
        member = members.Member.from_json(inp["member"])
        items = [catalog.Item.from_json(j) for j in inp.get("items", [])]
        out = Checkout(member.id)
        blocked = members.blocked_reasons(member)
        if blocked:
            for item in items:
                out.refused[item.id] = "; ".join(blocked)
            self.log.append(("refused", member.id, blocked))
            return out
        for item in items:
            if not catalog.can_take(item, member.id):
                out.refused[item.id] = "not available"
            elif not ratings.old_enough(member, item):
                out.refused[item.id] = "age rating"
            else:
                out.lent.append(item.id)
        self.log.append(("lent", member.id, list(out.lent)))
        return out

    def print_receipt(self, inp):
        out = self.checkout(inp)
        member = members.Member.from_json(inp["member"])
        lent = [catalog.Item.from_json(j) for j in inp["items"] if j["id"] in out.lent]
        return receipt(member, lent)
