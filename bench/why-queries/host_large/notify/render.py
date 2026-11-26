"""Message text per channel (not part of the routing decision)."""
from . import settings


def render(event, channel):
    title = event.title or f"{event.kind.title()} update"
    if channel == "email":
        return f"{settings.EMAIL_SUBJECT_PREFIX} {title}"
    if channel == "sms":
        return title[: settings.SMS_MAX_CHARS]
    return title
