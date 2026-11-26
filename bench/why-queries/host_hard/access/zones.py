"""Which zones a person may enter, before training and time are considered."""
from . import credentials
from .model import VISITOR

LOBBY = "lobby"


def role_zones(role, policy):
    return set(policy.zones_for_role(role))


def own_zones(person, policy):
    zones = role_zones(person.role, policy) if person.has_role else set()
    if credentials.badge_active(person):
        zones.add(LOBBY)
    return zones


def escort_zones(escort, policy):
    """Zones the escort may enter. Escorts are employees with active badges."""
    zones = role_zones(escort.role, policy) if escort.role != "none" else set()
    zones.add(LOBBY)
    return zones


def allowed_zones(person, policy):
    zones = own_zones(person, policy)
    if person.kind == VISITOR and credentials.escort_present(person):
        borrowed = escort_zones(person.escort, policy)
        zones |= {z for z in borrowed if z not in policy.no_visitor_zones}
    return zones


def may_enter_zone(person, zone, policy):
    return zone in allowed_zones(person, policy)
