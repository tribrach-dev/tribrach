#!/bin/sh
# CI has already run `lake build`, which compiled Parking (so every proof in
# Parking.Meters and Parking.Payments holds) and rewrote exported/. Check:
#  1. the committed exported/ is what the build writes (compared as JSON);
#  2. round trips, version reads and decoder = shape in Lean (Check.lean);
#  3. a JSON Schema validator agrees with Lean on every mutated message;
#  4. the exchanges' requests and responses fit their schemas;
#  5. the planted break: lowering payments' limit below the dearest session
#     makes meters' proofs fail, naming the theorem.
set -e
here=$(pwd)

python3 - <<'PY'
import json, pathlib, subprocess, sys
stale = []
for p in sorted(pathlib.Path("exported").rglob("*.json")):
    committed = subprocess.run(["git", "show", f"HEAD:examples/dto-parking/{p}"],
                               capture_output=True, text=True)
    if committed.returncode != 0 or json.loads(committed.stdout) != json.loads(p.read_text()):
        stale.append(str(p))
for s in stale:
    print(f"FAIL {s} is not committed as built")
if stale:
    sys.exit(1)
print("ok   exported/ matches the build")
PY

tmp=$(mktemp -d)
lake env lean --run Check.lean "$tmp/mutations.jsonl"

python3 - "$tmp/mutations.jsonl" <<'PY'
import json, pathlib, re, sys
import jsonschema
from jsonschema import ValidationError

def pattern(validator, regex, instance, schema):
    # ECMA-262: $ matches only at the very end; Python's also matches before
    # a final newline, so use \Z.
    if isinstance(instance, str) and re.search(regex[:-1] + r"\Z" if regex.endswith("$") else regex, instance) is None:
        yield ValidationError(f"{instance!r} does not match {regex!r}")

def x_tribrach(validator, value, instance, schema):
    # Bounds on whole numbers written as decimal strings (Ty.decimal).
    if isinstance(instance, str) and re.fullmatch(r"0|-?[1-9][0-9]*", instance):
        n = int(instance)
        if "minimum" in value and n < value["minimum"]:
            yield ValidationError(f"{n} is below {value['minimum']}")
        if "maximum" in value and n > value["maximum"]:
            yield ValidationError(f"{n} is above {value['maximum']}")

Validator = jsonschema.validators.extend(jsonschema.Draft202012Validator,
                                         {"pattern": pattern, "x-tribrach": x_tribrach})
schemas = {p.name[:-5]: Validator(json.loads(p.read_text()))
           for p in pathlib.Path("exported/schemas").glob("*.json")}

bad = total = 0
for line in open(sys.argv[1]):
    m = json.loads(line)
    total += 1
    got = schemas[m["schema"]].is_valid(m["doc"])
    if got != m["lean"]:
        bad += 1
        if bad <= 20:
            print(f"FAIL {m['schema']}: validator says {got}, Lean {m['lean']} for {json.dumps(m['doc'])}")
print(f"{'ok  ' if not bad else 'FAIL'} JSON Schema validator agrees with Lean on {total - bad} of {total} mutated messages")

for p in sorted(pathlib.Path("exported/exchanges").glob("*.json")):
    doc = json.loads(p.read_text())
    stem = doc["contract"] + (f".v{doc['version']}" if doc["contract"] == "meters.start" else "")
    before = bad
    for c in doc["cases"]:
        req_ok = schemas[stem + ".request"].is_valid(c["request"])
        if req_ok != (c["status"] == 200):
            bad += 1; print(f"FAIL {p.name} {c['id']}: request validity {req_ok} but status {c['status']}")
        if "response" in c and not schemas[stem + ".response"].is_valid(c["response"]):
            bad += 1; print(f"FAIL {p.name} {c['id']}: response doesn't fit its schema")
        for call in c["calls"]:
            if not (schemas[call["contract"] + ".request"].is_valid(call["request"]) and
                    schemas[call["contract"] + ".response"].is_valid(call["response"])):
                bad += 1; print(f"FAIL {p.name} {c['id']}: call to {call['contract']} doesn't fit")
    if bad == before:
        print(f"ok   {p} fits the schemas")
sys.exit(1 if bad else 0)
PY

# 5. The planted break, in a copy so the working tree is untouched.
mkdir -p "$tmp/copy"
cp -r Parking Parking.lean lakefile.toml lean-toolchain "$tmp/copy/"
sed -i 's|^path = "../.."|path = "'"$here"'/../.."|' "$tmp/copy/lakefile.toml"
sed -i 's/def maxAmount : Nat := 20000/def maxAmount : Nat := 1000/' "$tmp/copy/Parking/Payments.lean"
if (cd "$tmp/copy" && lake build Parking.Meters > "$tmp/break.log" 2>&1); then
  echo "FAIL lowering payments' limit should break meters' proofs"; exit 1
fi
# Lean names the line, not the theorem, so find which theorem holds that line.
if python3 - "$tmp/break.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
lines = [int(n) for n in re.findall(r"error: Parking/Meters\.lean:(\d+)", log)]
src = open("Parking/Meters.lean").read().splitlines()
def theorem_at(n):
    for i in range(n - 1, -1, -1):
        m = re.match(r"theorem (\S+)", src[i])
        if m:
            return m.group(1)
names = sorted({theorem_at(n) for n in lines})
print("     failing:", ", ".join(map(str, names)))
sys.exit(0 if names == ["charge_within_limit"] else 1)
PY
then
  echo "ok   lowering payments' limit to 1000 breaks Meters.charge_within_limit"
else
  echo "FAIL expected only charge_within_limit to fail:"; cat "$tmp/break.log"; exit 1
fi
rm -rf "$tmp"
