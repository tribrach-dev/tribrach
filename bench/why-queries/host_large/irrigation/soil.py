"""Soil state per zone."""


def dry_threshold(kind, soil):
    return soil.dry_below.get(kind, soil.default_dry_below)


def is_dry(zone, soil):
    return zone.moisture < dry_threshold(zone.kind, soil)


def is_parched(zone, soil):
    return zone.moisture < soil.parched_below


def deficit(zone, soil):
    """How many points below its threshold a zone is (0 if not dry)."""
    return max(0, dry_threshold(zone.kind, soil) - zone.moisture)
