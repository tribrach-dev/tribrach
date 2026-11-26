"""Gate settings."""

# Deploy windows: day -> (first hour, hour the window closes)
WINDOWS = {
    "mon": (9, 17),
    "tue": (9, 17),
    "wed": (9, 17),
    "thu": (9, 17),
    "fri": (9, 15),
}

RISK_LEVELS = ("low", "medium", "high")

# Tiers whose migration announcements go to the SRE channel as well.
MIGRATION_SRE_TIERS = (1,)
TIERS = (1, 2, 3)

# Notifications
CHAT_CHANNEL = "#deploys"
DIGEST_HOUR = 17
