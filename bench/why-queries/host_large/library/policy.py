"""Lending policy settings, as published in the branch handbook."""

POLICY = {
    "fines": {
        "block_at_cents": 500,       # owing this much or more blocks borrowing
        "waive_below_cents": 50,     # small balances are shown but not charged
    },
    "loan_limits": {"standard": 5, "plus": 10},
    "loan_days": {"book": 21, "dvd": 7, "periodical": 7},
    "ages": {"teen": 13, "adult": 18},
    "renewals": {"max": 2},
}


def get(path, default=None):
    node = POLICY
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node
