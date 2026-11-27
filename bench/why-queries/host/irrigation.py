"""Garden irrigation controller: decides which valves to open this hour."""

DRY_THRESHOLDS = {  # percent soil moisture
    "lawn": 30,
    "beds": 40,
    "pots": 50,
}
DEFAULT_DRY_THRESHOLD = 30
PARCHED_BELOW = 15
RAIN_POSTPONE_MM = 5
FROST_MAX_C = 2

MORNING = (5, 9)
EVENING = (19, 22)


def is_watering_hour(hour):
    start, end = MORNING
    if start <= hour < end:
        return True
    start, end = EVENING
    return start <= hour < end


def is_dry(zone):
    threshold = DRY_THRESHOLDS.get(zone["kind"], DEFAULT_DRY_THRESHOLD)
    return zone["moisture"] < threshold


def is_parched(zone):
    return zone["moisture"] < PARCHED_BELOW


def weather_blocks(conditions):
    """Rain on the way or frost: hold off scheduled watering."""
    if conditions["rain_mm"] >= RAIN_POSTPONE_MM:
        return True
    return conditions["temp_c"] <= FROST_MAX_C


def zone_actions(zone, conditions):
    actions = []
    if zone["hold"]:
        if is_parched(zone):
            actions.append("alert " + zone["name"])
        return actions
    if zone["kind"] == "pots" and is_parched(zone):
        # Pots dry out fast: water them whatever the hour or the forecast.
        if conditions["temp_c"] > FROST_MAX_C:
            actions.append("water " + zone["name"])
        return actions
    if is_dry(zone) and is_watering_hour(conditions["hour"]):
        if not weather_blocks(conditions):
            actions.append("water " + zone["name"])
    return actions


def decide(inp):
    """Return the sorted list of decisions, such as ["water lawn"]."""
    conditions = {k: inp[k] for k in ("hour", "temp_c", "rain_mm")}
    out = []
    for zone in inp["zones"]:
        out.extend(zone_actions(zone, conditions))
    return sorted(out)
