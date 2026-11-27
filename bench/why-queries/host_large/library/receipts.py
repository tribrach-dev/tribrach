"""Printed receipts (not part of the lending decision)."""
import datetime as dt

from .catalog import due_days


def receipt(member, items, today=None):
    today = today or dt.date(2026, 1, 1)
    lines = [f"Member {member.id}"]
    for item in items:
        due = today + dt.timedelta(days=due_days(item))
        lines.append(f"  {item.id} ({item.kind}) due {due.isoformat()}")
    lines.append(f"{len(items)} item(s). Thank you!")
    return "\n".join(lines)
