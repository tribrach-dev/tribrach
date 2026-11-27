"""Library lending desk: which of the requested items may the member take home."""

FINE_LIMIT_CENTS = 500
LOAN_LIMITS = {"standard": 5, "plus": 10}
TEEN_AGE = 13
ADULT_AGE = 18


def member_can_borrow(member):
    if member["status"] != "active":
        return False
    if member["fines_cents"] >= FINE_LIMIT_CENTS:
        return False
    limit = LOAN_LIMITS.get(member["tier"], LOAN_LIMITS["standard"])
    return member["loans"] < limit


def old_enough(member, item):
    rating = item["rating"]
    if rating == "teen":
        return member["age"] >= TEEN_AGE
    elif rating == "adult":
        return member["age"] >= ADULT_AGE
    return rating == "all"


def item_available_to(item, member):
    if item["status"] == "on_shelf":
        return item["kind"] != "reference"
    if item["status"] == "on_hold":
        return item.get("held_for") == member["id"]
    return False


def decide(inp):
    """Return the sorted list of decisions, such as ["lend m1 i2"]."""
    member = inp["member"]
    if not member_can_borrow(member):
        return []
    out = []
    for item in inp["items"]:
        if item_available_to(item, member) and old_enough(member, item):
            out.append(f"lend {member['id']} {item['id']}")
    return sorted(out)
