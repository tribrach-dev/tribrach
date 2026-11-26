"""Weekly change-management report (reads the audit log only)."""
from collections import Counter


def blockers_by_kind(log):
    c = Counter()
    for r in log.blocked():
        for b in r["blockers"]:
            c[b.split(":", 1)[0]] += 1
    return c.most_common()


def self_approved(log):
    """Changes where the author is among the approvers (shown for review;
    the gate already ignores such approvals)."""
    return [r["change"] for r in log.rows if r["author"] in r["approvers"]]


def render(log):
    lines = [f"changes evaluated: {len(log.rows)}", f"blocked: {len(log.blocked())}"]
    for kind, n in blockers_by_kind(log):
        lines.append(f"  {kind}: {n}")
    sa = self_approved(log)
    if sa:
        lines.append("self-approved (ignored): " + ", ".join(sa))
    return "\n".join(lines)
