"""Notification delivery: which channels an event goes out on."""

RATE_LIMIT_PER_HOUR = 3


def in_quiet_hours(hour, start, end):
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    # The window crosses midnight, e.g. 22 -> 7.
    return hour >= start or hour < end


def is_urgent(event):
    return event["kind"] == "security" or event["priority"] == "urgent"


def channels_for(inp):
    user, event = inp["user"], inp["event"]
    enabled = set(user["channels"])
    urgent = is_urgent(event)
    if urgent:
        throttled = False
    else:
        throttled = inp["sent_last_hour"] >= RATE_LIMIT_PER_HOUR
    quiet = in_quiet_hours(inp["hour"], user["quiet_start"], user["quiet_end"])

    out = []
    if "push" in enabled and not throttled and (urgent or not quiet):
        out.append("push")
    if "email" in enabled and inp["sent_last_hour"] < RATE_LIMIT_PER_HOUR:
        out.append("email")
    if "sms" in enabled and user["sms_verified"] and urgent:
        out.append("sms")
    return out


def decide(inp):
    """Return the sorted list of decisions, such as ["deliver email"]."""
    return sorted("deliver " + c for c in channels_for(inp))
