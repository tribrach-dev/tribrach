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

if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "inputs")
    out.mkdir(exist_ok=True)
    for name, gen in GEN.items():
        r = random.Random(f"tribrach-why-bench-{name}")
        inputs = [gen(r) for _ in range(N)] + EDGES[name]
        cases = [{"id": f"{PREFIX[name]}-{k + 1:02d}", "input": x} for k, x in enumerate(inputs)]
        (out / f"{name}.json").write_text(json.dumps(cases, indent=1) + "\n")
