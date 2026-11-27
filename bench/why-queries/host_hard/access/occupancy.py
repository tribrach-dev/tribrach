"""Weekly occupancy report (reads the audit log; no effect on access)."""
from collections import defaultdict

from . import clock
from .model import Now


def busiest_zones(audit_log, top=3):
    counts = defaultdict(int)
    for r in audit_log.rows():
        if r["open"]:
            counts[r["zone"]] += 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:top]


def in_report(row, policy):
    day, _, hh = row["when"].partition(" ")
    hour = int(hh.split(":")[0])
    return clock.in_report_window(Now(day=day, hour=hour), policy)


def summary(audit_log, policy):
    rows = [r for r in audit_log.rows() if in_report(r, policy)]
    opened = sum(1 for r in rows if r["open"])
    lines = [f"taps in report window: {len(rows)}", f"opened: {opened}"]
    for zone, n in busiest_zones(audit_log):
        lines.append(f"  {zone}: {n}")
    return "\n".join(lines)
