"""Per-user rate limiting."""
from . import settings


def over_limit(ctx):
    return ctx.sent_last_hour >= settings.RATE_LIMIT_PER_HOUR


def push_throttled(ctx, urgent):
    """Push is throttled for non-urgent events once the user is over the limit."""
    if urgent:
        return False
    else:
        return over_limit(ctx)


def email_throttled(ctx):
    return over_limit(ctx)
