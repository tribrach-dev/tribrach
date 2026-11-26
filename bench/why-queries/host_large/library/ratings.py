"""Age ratings."""
from . import policy


def minimum_age(rating):
    ages = policy.get("ages")
    if rating == "teen":
        return ages["teen"]
    elif rating == "adult":
        return ages["adult"]
    return 0 if rating == "all" else None


def old_enough(member, item):
    need = minimum_age(item.rating)
    return need is not None and member.age >= need
