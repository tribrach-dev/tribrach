"""Time-of-day rules."""


def _in_span(hour, span):
    start, end = span
    if start <= end:
        return start <= hour < end
    return hour >= start or hour < end  # the span crosses midnight


def is_business_hours(now, policy):
    if now.holiday:
        return False
    if now.day not in policy.business_days:
        return False
    return _in_span(now.hour, policy.business_span)


def is_night(now, policy):
    return _in_span(now.hour, policy.night_span)


def in_report_window(now, policy):
    """For the occupancy report only."""
    return now.day in policy.report_days and _in_span(now.hour, policy.report_span)


def describe(now):
    return f"{now.day} {now.hour:02d}:00" + (" (holiday)" if now.holiday else "")
