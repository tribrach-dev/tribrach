"""Write the benchmark's test inputs (inputs/<model>.json) from a fixed seed.

Expected decisions come from the Lean specification, not from this script:
`lake exe why expect <model> inputs/<model>.json > vectors/<model>.json`.
"""
import json
import random
import sys
from pathlib import Path

N = 30


def irrigation(r):
    zones = []
    for name, kind in [("lawn", "lawn"), ("beds", "beds"), ("pots", "pots")]:
        if r.random() < 0.8:
            zones.append({"name": name, "kind": kind,
                          "moisture": r.choice([8, 12, 20, 28, 33, 37, 45, 55, 70]),
                          "hold": r.random() < 0.2})
    return {"hour": r.choice([3, 5, 6, 8, 9, 12, 18, 19, 21, 22, 23]),
            "temp_c": r.choice([-3, 1, 2, 3, 8, 15, 24]),
            "rain_mm": r.choice([0, 0, 1, 4, 5, 6, 12]),
            "zones": zones}


def library(r):
    member = {"id": "m1", "age": r.choice([9, 12, 13, 15, 17, 18, 30, 67]),
              "status": r.choice(["active"] * 5 + ["suspended", "expired"]),
              "fines_cents": r.choice([0, 0, 120, 499, 500, 650]),
              "loans": r.choice([0, 2, 4, 5, 6, 9, 10]),
              "tier": r.choice(["standard", "standard", "plus"])}
    items = []
    for i in range(r.choice([1, 2, 3])):
        status = r.choice(["on_shelf", "on_shelf", "on_hold", "out"])
        items.append({"id": f"i{i + 1}",
                      "kind": r.choice(["book", "book", "dvd", "periodical", "reference"]),
                      "rating": r.choice(["all", "all", "teen", "adult"]),
                      "status": status,
                      "held_for": r.choice(["m1", "m2"]) if status == "on_hold" else None})
    return {"member": member, "items": items}


def notify(r):
    qs, qe = r.choice([(22, 7), (23, 6), (21, 8), (0, 6), (13, 15), (8, 8)])
    chans = [c for c in ["push", "email", "sms"] if r.random() < 0.7]
    return {"hour": r.choice([0, 3, 6, 7, 9, 14, 21, 22, 23]),
            "sent_last_hour": r.choice([0, 1, 2, 3, 4]),
            "user": {"quiet_start": qs, "quiet_end": qe, "channels": chans,
                     "sms_verified": r.random() < 0.6},
            "event": {"kind": r.choice(["security", "reminder", "social"]),
                      "priority": r.choice(["low", "normal", "normal", "urgent"])}}


PREFIX = {"irrigation": "irr", "library": "lib", "notify": "ntf"}
GEN = {"irrigation": irrigation, "library": library, "notify": notify}

# Hand-written boundary cases, appended after the random ones.
EDGES = {
    "irrigation": [
        {"hour": 6, "temp_c": 15, "rain_mm": 0,
         "zones": [{"name": "beds", "kind": "beds", "moisture": 37, "hold": False}]},
        {"hour": 22, "temp_c": 15, "rain_mm": 0,
         "zones": [{"name": "lawn", "kind": "lawn", "moisture": 20, "hold": False}]},
        {"hour": 12, "temp_c": 1, "rain_mm": 0,
         "zones": [{"name": "pots", "kind": "pots", "moisture": 10, "hold": False}]},
    ],
    "library": [
        {"member": {"id": "m1", "age": 30, "status": "active", "fines_cents": 500,
                    "loans": 0, "tier": "standard"},
         "items": [{"id": "i1", "kind": "book", "rating": "all", "status": "on_shelf",
                    "held_for": None}]},
    ],
    "notify": [],
}

def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "inputs")
    out.mkdir(exist_ok=True)
    hard_inputs(out)
    hidden_inputs(out)
    feature_inputs(out)
    for name, gen in GEN.items():
        r = random.Random(f"tribrach-why-bench-{name}")
        inputs = [gen(r) for _ in range(N)] + EDGES[name]
        cases = [{"id": f"{PREFIX[name]}-{k + 1:02d}", "input": x} for k, x in enumerate(inputs)]
        (out / f"{name}.json").write_text(json.dumps(cases, indent=1) + "\n")


# ---------------------------------------------------------------- hard suite

def access(r):
    kind = r.choice(["employee"] * 4 + ["contractor", "contractor", "visitor"])
    role = "none" if kind == "visitor" else r.choice(
        ["engineer", "lab_tech", "facilities", "security", "exec", "none"])
    person = {"id": {"employee": "e", "contractor": "c", "visitor": "v"}[kind] + str(r.randint(1, 9)),
              "kind": kind, "role": role,
              "badge": r.choice(["active"] * 6 + ["suspended", "lost"]),
              "contract_days_left": r.choice([-3, 0, 2, 9, 40, 120]) if kind == "contractor" else None,
              "training": sorted(r.sample(["lab_safety", "server_access", "fall_protection"], r.randint(0, 2))),
              "responder": r.random() < 0.1,
              "escort": None}
    if kind == "visitor" and r.random() < 0.8:
        person["escort"] = {"id": "e" + str(r.randint(1, 9)),
                            "role": r.choice(["engineer", "lab_tech", "facilities"]),
                            "on_site": r.random() < 0.85,
                            "training": sorted(r.sample(["lab_safety", "server_access"], r.randint(0, 2)))}
    zone = r.choice(["lobby", "office", "office", "lab", "server", "loading", "roof"])
    return {"now": {"day": r.choice(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]),
                    "hour": r.choice([2, 7, 9, 12, 16, 18, 19, 20, 23]),
                    "holiday": r.random() < 0.1},
            "site": {"lockdown": r.random() < 0.08, "fire_alarm": r.random() < 0.08},
            "person": person,
            "door": {"id": f"d-{zone}-{r.randint(1, 3)}", "zone": zone,
                     "after_hours": r.random() < 0.3, "egress": r.random() < 0.2}}


def deploy(r):
    author = "u" + str(r.randint(1, 5))
    approvals = []
    for _ in range(r.choice([1, 2, 2, 3])):
        approvals.append({"by": "u" + str(r.randint(1, 9)),
                          "role": r.choice(["owner", "owner", "sre", "security", "peer"])})
    tier = r.choice([1, 2, 2, 3])
    return {"change": {"id": "c" + str(r.randint(100, 999)),
                       "service": r.choice(["payments", "search", "docs", "auth", "feed"]),
                       "author": author, "risk": r.choice(["low", "medium", "medium", "high"]),
                       "migration": r.random() < 0.2, "hotfix": r.random() < 0.15},
            "service": {"tier": tier, "error_budget_pct": r.choice([5, 12, 18, 25, 40, 80]),
                        "canary": r.random() < 0.6},
            "checks": {"unit": r.choice(["pass"] * 9 + ["fail"]),
                       "integration": r.choice(["pass"] * 9 + ["fail"]),
                       "security": r.choice(["pass"] * 6 + ["fail"]),
                       "perf": r.choice(["pass"] * 4 + ["fail"])},
            "approvals": approvals,
            "calendar": {"day": r.choice(["mon", "tue", "wed", "thu", "fri", "fri", "sat"]),
                         "hour": r.choice([8, 10, 10, 13, 13, 15, 16, 19]), "freeze": r.random() < 0.05},
            "oncall": {"acked": r.random() < 0.7}}


def access_wide(r):
    """Like access(), but every hour and the boundary values are likely, for
    the fix suite's hidden vectors."""
    x = access(r)
    x["now"]["hour"] = r.randrange(24)
    x["now"]["holiday"] = r.random() < 0.2
    x["site"]["lockdown"] = r.random() < 0.2
    p = x["person"]
    p["responder"] = r.random() < 0.25
    if p["kind"] == "contractor":
        p["contract_days_left"] = r.choice([-1, 0, 1, 2, 6, 7, 8, 9, 30])
    if r.random() < 0.3:
        p["training"] = sorted(set(p["training"]) | {r.choice(["lab_safety", "server_access", "fall_protection"])})
    x["door"]["after_hours"] = r.random() < 0.5
    return x


def deploy_wide(r):
    """Like deploy(), with boundary budgets and hours, self-approvals and
    more hotfixes and migrations, for the fix suite's hidden vectors."""
    x = deploy(r)
    x["service"]["error_budget_pct"] = r.choice([5, 15, 19, 20, 21, 25, 60])
    x["calendar"]["hour"] = r.choice([8, 9, 12, 14, 15, 16, 17, 18])
    x["calendar"]["day"] = r.choice(["mon", "tue", "wed", "thu", "fri", "fri", "sat"])
    x["change"]["migration"] = r.random() < 0.35
    x["change"]["hotfix"] = r.random() < 0.3
    x["checks"]["perf"] = r.choice(["pass", "pass", "fail", "skipped"])
    x["checks"]["security"] = r.choice(["pass", "pass", "pass", "fail", "skipped"])
    if r.random() < 0.4:
        x["approvals"].append({"by": x["change"]["author"],
                               "role": r.choice(["owner", "sre", "peer"])})
    return x


def access_feature(r):
    """access_wide() plus the fields the feature versions add (temporary
    grants, quarantine), for the feature shift's hidden vectors."""
    x = access_wide(r)
    zones = ["lobby", "office", "lab", "server", "loading", "roof"]
    p, door = x["person"], x["door"]
    # Mostly taps that could succeed, so the new rules decide something.
    if r.random() < 0.8:
        p["badge"] = "active"
        if p["kind"] == "contractor":
            p["contract_days_left"] = r.choice([3, 9, 30])
        need = {"lab": "lab_safety", "server": "server_access", "roof": "fall_protection"}.get(door["zone"])
        if need and r.random() < 0.7:
            p["training"] = sorted(set(p["training"]) | {need})
    if r.random() < 0.5:
        p["temp_grants"] = [{"zone": door["zone"] if r.random() < 0.6 else r.choice(zones),
                             "days_left": r.choice([-2, 0, 1, 5, 30])}
                            for _ in range(r.randint(1, 2))]
    if r.random() < 0.35:
        x["site"]["quarantine"] = sorted(set(r.sample(zones, r.randint(1, 2)) + [x["door"]["zone"]] * (r.random() < 0.6)))
    if r.random() < 0.3:
        x["now"]["holiday"] = True
    if r.random() < 0.25 and p["kind"] != "visitor":
        p["role"] = "facilities"
    return x


def deploy_feature(r):
    """deploy_wide() plus the fields the feature versions add (tier 0,
    dependencies and service freezes, touched paths)."""
    x = deploy_wide(r)
    services = ["payments", "search", "docs", "auth", "feed"]
    if r.random() < 0.35:
        x["service"]["tier"] = 0
    if r.random() < 0.5:
        x["change"]["depends_on"] = sorted(r.sample(services, r.randint(1, 2)))
    if r.random() < 0.4:
        x["calendar"]["frozen"] = sorted(r.sample(services, r.randint(1, 2)))
    if r.random() < 0.5:
        x["change"]["touches"] = sorted(r.sample(["auth/session.py", "crypto/keys.py", "api/handlers.py",
                                                  "docs/index.md", "authz/README.md", "lib/crypto_utils.py"],
                                                 r.randint(1, 2)))
    for _ in range(r.choice([0, 0, 1, 2])):
        x["approvals"].append({"by": "u" + str(r.randint(1, 9)), "role": r.choice(["sre", "security"])})
    # Mostly changes that could ship, so the new rules decide something.
    if r.random() < 0.7:
        x["checks"] = {k: "pass" for k in x["checks"]}
        x["approvals"].append({"by": "u" + str(r.randint(6, 9)), "role": "owner"})
        x["calendar"]["freeze"] = False
        if r.random() < 0.7:
            x["calendar"]["day"], x["calendar"]["hour"] = r.choice(["mon", "tue", "wed", "thu"]), r.choice([10, 13, 15])
        if x["service"]["tier"] == 0 and r.random() < 0.7:
            x["approvals"] += [{"by": "u7", "role": "sre"}, {"by": "u8", "role": "sre"}]
            if r.random() < 0.3:
                x["change"]["hotfix"], x["oncall"]["acked"] = True, True
                x["calendar"]["hour"] = r.choice([7, 18, 21])
        if r.random() < 0.3:
            x["checks"][r.choice(["perf", "security"])] = r.choice(["skipped", "fail"])
        if r.random() < 0.15:
            x["service"]["tier"], x["checks"]["security"] = 3, "skipped"
        if r.random() < 0.4:
            x["approvals"].append({"by": "u9", "role": "security"})
    return x


HARD = {"access": (access, "acc"), "deploy": (deploy, "dep")}
WIDE = {"access": (access_wide, "hacc"), "deploy": (deploy_wide, "hdep")}
WIDE_N = 800
HARD_N = 120


def hard_inputs(out):
    for name, (gen, prefix) in HARD.items():
        r = random.Random(f"tribrach-why-bench-hard-{name}")
        cases = [{"id": f"{prefix}-{k + 1:02d}", "input": gen(r)} for k in range(HARD_N)]
        (out / f"{name}.json").write_text(json.dumps(cases, indent=1) + "\n")


FEATURE = {"access": (access_feature, "facc"), "deploy": (deploy_feature, "fdep")}
FEATURE_N = 2000


def feature_inputs(out):
    """Inputs for the feature shift's hidden vectors."""
    for name, (gen, prefix) in FEATURE.items():
        r = random.Random(f"tribrach-why-bench-feature-{name}")
        cases = [{"id": f"{prefix}-{k + 1:04d}", "input": gen(r)} for k in range(FEATURE_N)]
        (out / f"feature-{name}.json").write_text(json.dumps(cases, indent=1) + "\n")


def hidden_inputs(out):
    """Inputs for the fix suite's hidden vectors (never shown to a session)."""
    for name, (gen, prefix) in WIDE.items():
        r = random.Random(f"tribrach-why-bench-hidden-{name}")
        cases = [{"id": f"{prefix}-{k + 1:03d}", "input": gen(r)} for k in range(WIDE_N)]
        (out / f"hidden-{name}.json").write_text(json.dumps(cases, indent=1) + "\n")


if __name__ == "__main__":
    main()
