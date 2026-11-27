"""Per-zone decisions."""
from . import schedule, soil, weather


def decide_zone(zone, cond, settings, plan):
    s = settings
    if zone.hold:
        if soil.is_parched(zone, s.soil):
            plan.alerts.append(zone.name)
            plan.note(zone.name, "parched but on hold")
        else:
            plan.note(zone.name, "on hold")
        return

    if zone.kind == "pots" and soil.is_parched(zone, s.soil):
        # Pots dry out fast: water them at any hour and whatever the forecast.
        if not weather.frost(cond, s.weather):
            plan.water.append(zone.name)
            plan.note(zone.name, "parched pots")
        else:
            plan.note(zone.name, "parched pots, but frost")
        return

    if not soil.is_dry(zone, s.soil):
        plan.note(zone.name, "moist enough")
        return
    if not schedule.in_window(cond.hour, s.schedule.windows):
        wait = schedule.next_window_start(cond.hour, s.schedule.windows)
        plan.note(zone.name, f"dry; next window in {wait} h")
        return
    blocked = weather.scheduled_watering_blocked(cond, s.weather)
    if blocked:
        plan.note(zone.name, "dry; " + " and ".join(blocked))
        return
    plan.water.append(zone.name)
    plan.note(zone.name, f"dry by {soil.deficit(zone, s.soil)} points")
