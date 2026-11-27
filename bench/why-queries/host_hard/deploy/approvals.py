"""Who approved, and is it enough?"""
OWNER, SRE, SECURITY, PEER = "owner", "sre", "security", "peer"


def independent(approvals, change):
    """Approvals from someone other than the author."""
    return [a for a in approvals if a.by != change.author]


def approvers(approvals):
    return {a.by for a in approvals}


def has_role(approvals, role):
    return any(a.role == role for a in approvals)


def enough_for_risk(approvals, change):
    ind = independent(approvals, change)
    if change.risk == "low":
        return len(ind) >= 1
    if change.risk == "medium":
        return has_role(ind, OWNER)
    if change.risk == "high":
        return has_role(ind, OWNER) and len(approvers(ind)) >= 2
    return False


def sre_approved(approvals, change):
    # Checked on its own because hotfixes and migrations ask for it directly.
    return any(a.role == SRE and a.by != change.author for a in approvals)


def owner_approved(approvals, change):
    return has_role(independent(approvals, change), OWNER)


def summary(approvals, change):
    ind = independent(approvals, change)
    roles = sorted({a.role for a in ind})
    return f"{len(approvers(ind))} independent approver(s): {', '.join(roles) or 'none'}"
