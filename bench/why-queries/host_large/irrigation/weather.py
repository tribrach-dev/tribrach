"""Weather gates."""


def rain_expected(cond, weather):
    return cond.rain_mm >= weather.rain_postpone_mm


def frost(cond, weather):
    return cond.temp_c <= weather.frost_max_c


def scheduled_watering_blocked(cond, weather):
    """Reasons scheduled watering is off this tick (empty if none)."""
    reasons = []
    if rain_expected(cond, weather):
        reasons.append("rain expected")
    if frost(cond, weather):
        reasons.append("frost")
    return reasons
