"""May this person use this door at this time?"""
from . import clock

LOADING = "loading"


def hours_ok(person, door, now, policy):
    if clock.is_business_hours(now, policy):
        return True
    if door.after_hours and not clock.is_night(now, policy):
        return True
    if person.role == "security":
        return True
    if person.role == "facilities" and door.zone == LOADING:
        return True
    return False
