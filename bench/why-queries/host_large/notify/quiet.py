"""Quiet hours."""


def in_quiet_hours(hour, start, end):
    """Is `hour` inside [start, end)? The window may cross midnight."""
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    # The window crosses midnight, e.g. 22 -> 7.
    return hour >= start or hour < end


def hours_until_quiet_ends(hour, start, end):
    if not in_quiet_hours(hour, start, end):
        return 0
    return (end - hour) % 24
