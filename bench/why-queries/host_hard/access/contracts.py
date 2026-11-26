"""Contractor contract status."""
from .model import CONTRACTOR


def _days(person):
    if person.kind != CONTRACTOR or person.contract_days_left is None:
        return None
    return person.contract_days_left


def is_running(person):
    """A contractor whose contract hasn't ended."""
    days = _days(person)
    return days is not None and days > 0


def has_ended(person):
    days = _days(person)
    return days is not None and days <= 0


def is_ending_soon(person, policy):
    days = _days(person)
    return days is not None and 0 < days <= policy.expiring_within_days


def renewal_reminder_due(person, policy):
    """For the contractor-management dashboard, not for access."""
    days = _days(person)
    return days is not None and 0 < days <= policy.renewal_reminder_days
