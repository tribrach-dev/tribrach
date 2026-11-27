"""Service-wide delivery settings."""

RATE_LIMIT_PER_HOUR = 3          # non-urgent notifications per user per hour
URGENT_KINDS = frozenset({"security"})
URGENT_PRIORITIES = frozenset({"urgent"})
CHANNEL_ORDER = ("push", "email", "sms")
EMAIL_SUBJECT_PREFIX = "[Notice]"
SMS_MAX_CHARS = 160
