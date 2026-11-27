"""Deploy windows, freezes and hotfixes."""
from . import settings


def in_window(cal):
    span = settings.WINDOWS.get(cal.day)
    if span is None:
        return False
    start, end = span
    return start <= cal.hour < end


def may_ship_now(req, sre_ok):
    cal = req.calendar
    if in_window(cal) and not cal.freeze:
        return True
    if req.change.hotfix and sre_ok and req.oncall_acked:
        return True
    return False


def next_window(cal):
    order = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    i = order.index(cal.day)
    for k in range(0, 8):
        day = order[(i + k) % 7]
        span = settings.WINDOWS.get(day)
        if span and (k > 0 or cal.hour < span[1]):
            return day, max(span[0], cal.hour if k == 0 else span[0])
    return None
