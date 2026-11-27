"""Is the badge itself good for entry?"""
from . import contracts
from .model import CONTRACTOR, EMPLOYEE, VISITOR

ACTIVE = "active"
FLAGGED = frozenset({"suspended", "lost"})


def badge_active(person):
    return person.badge == ACTIVE


def badge_flagged(person):
    return person.badge in FLAGGED


def escort_present(person):
    return person.escort is not None and person.escort.on_site


def credential_valid(person):
    if not badge_active(person):
        return False
    if person.kind == EMPLOYEE:
        return True
    if person.kind == CONTRACTOR:
        return contracts.is_running(person)
    if person.kind == VISITOR:
        return escort_present(person)
    return False
