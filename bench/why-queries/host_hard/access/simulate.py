"""Replay a day of taps against a policy, for policy authors."""
import itertools

from .decision import evaluate
from .model import Door, Now, Person, Site, Tap


def sweep_hours(person, door, policy, day="tue", site=None):
    """For each hour of a day: would this person get through this door?"""
    site = site or Site()
    out = {}
    for hour in range(24):
        tap = Tap(now=Now(day=day, hour=hour), site=site, person=person, door=door)
        d = evaluate(tap, policy)
        out[hour] = "open" if d.open else "2fa" if d.two_factor else "-"
    return out


def matrix(people, doors, policy, now):
    """Who can open what, right now."""
    rows = {}
    for p, d in itertools.product(people, doors):
        rows[(p.id, d.id)] = evaluate(Tap(now=now, site=Site(), person=p, door=d), policy).open
    return rows


def demo_people():
    return [
        Person("e1", "employee", "engineer", "active", None, frozenset(), False, None),
        Person("l1", "employee", "lab_tech", "active", None, frozenset({"lab_safety"}), False, None),
        Person("f1", "employee", "facilities", "active", None, frozenset({"server_access"}), False, None),
    ]


def demo_doors():
    return [Door("d-lobby", "lobby"), Door("d-office", "office"), Door("d-lab", "lab", after_hours=True)]
