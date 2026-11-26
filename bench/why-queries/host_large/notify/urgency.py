"""Which events are urgent."""
from . import settings


def is_urgent(event):
    return event.kind in settings.URGENT_KINDS or event.priority in settings.URGENT_PRIORITIES
