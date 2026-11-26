"""When the controller may run scheduled watering."""


def in_window(hour, windows):
    for start, end in windows:
        if start <= hour < end:
            return True
    return False


def next_window_start(hour, windows):
    """Hours until the next window opens (0 if one is open now)."""
    if in_window(hour, windows):
        return 0
    starts = sorted(s for s, _ in windows)
    for s in starts:
        if s > hour:
            return s - hour
    return 24 - hour + starts[0]
