"""Training requirements per zone."""
from . import zones
from .model import VISITOR


def requirement(zone, policy):
    return policy.training_for(zone)


def _trained(training, zone, policy):
    need = requirement(zone, policy)
    return need is None or need in training


def escort_cleared(escort, zone, policy):
    return zone in zones.escort_zones(escort, policy) and _trained(escort.training, zone, policy)


def cleared(person, zone, policy):
    """Allowed into the zone and trained for it (a visitor may rely on their
    escort's training)."""
    if not zones.may_enter_zone(person, zone, policy):
        return False
    if _trained(person.training, zone, policy):
        return True
    if person.kind == VISITOR and person.escort is not None:
        return escort_cleared(person.escort, zone, policy)
    return False


def missing_training(person, zone, policy):
    need = requirement(zone, policy)
    if need is None or need in person.training:
        return None
    return need
