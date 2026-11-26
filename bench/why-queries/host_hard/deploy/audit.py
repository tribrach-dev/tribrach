"""Gate decisions, kept for the change-management report."""
import json


class Log:
    def __init__(self):
        self.rows = []

    def add(self, req, v):
        self.rows.append({
            "change": req.change.id,
            "service": req.change.service,
            "author": req.change.author,
            "risk": req.change.risk,
            "approvers": sorted({a.by for a in req.approvals}),
            "decisions": v.decisions(),
            "blockers": list(v.blockers),
        })

    def blocked(self):
        return [r for r in self.rows if r["blockers"]]

    def by_author(self, author):
        return [r for r in self.rows if r["author"] == author]

    def dump(self):
        return "\n".join(json.dumps(r, sort_keys=True) for r in self.rows)
