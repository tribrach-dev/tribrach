#!/bin/sh
# CI has already run `lake build`, which compiled CaptureSchema and rewrote
# ../../schema/capture.schema.json. Check that:
#  1. the committed schema is what the build writes (compared as JSON);
#  2. the Lean checker agrees with the pattern conformance cases and with
#     the capture goldens;
#  3. the Lean checker, the reference tree matcher (tools/conformance.py)
#     and the exported regexes agree on many generated strings near the
#     conformance cases.
set -e

python3 - <<'PY'
import json, subprocess, sys
path = "schema/capture.schema.json"
committed = json.loads(subprocess.run(["git", "show", "HEAD:" + path], capture_output=True,
                                      text=True, check=True, cwd="../..").stdout)
built = json.load(open("../../" + path))
if committed != built:
    print(f"FAIL {path} is stale; the build wrote:")
    print(json.dumps(built, indent=2))
    sys.exit(1)
print(f"ok   {path} matches the build")
PY

lake env lean --run Check.lean ../..

tmp=$(mktemp -d)
python3 - "$tmp" <<'PY'
import json, random, re, sys
tmp = sys.argv[1]
cases = json.load(open("../../tests/conformance/patterns.json"))["cases"]
alphabet = list("09afgzAFZ-_./\\:+ T\t\n") + ["..", "\u2028", "\u2029", "\x7f", "\x00", "\x1f", "é"]
rng = random.Random(20261126)
def mutate(s):
    s = list(s)
    for _ in range(rng.randint(1, 3)):
        op = rng.randrange(3)
        i = rng.randint(0, len(s))
        if op == 0 or not s:
            s.insert(i, rng.choice(alphabet))
        elif op == 1:
            del s[min(i, len(s) - 1)]
        else:
            s[min(i, len(s) - 1)] = rng.choice(alphabet)
    return "".join(s)
samples = {}
for c in cases:
    seeds = c["accept"] + c["reject"]
    samples[c["name"]] = sorted({mutate(rng.choice(seeds)) for _ in range(3000)})
json.dump(samples, open(f"{tmp}/in.json", "w"))
PY
lake env lean --run Check.lean fuzz "$tmp/in.json" "$tmp/out.json"
python3 - "$tmp" <<'PY'
import json, re, sys
sys.path.insert(0, "../../tools")
from conformance import tree_matches
tmp = sys.argv[1]
all_cases = json.load(open("../../tests/conformance/patterns.json"))["cases"]
cases = {c["name"]: c["regex"] for c in all_cases}
trees = {c["name"]: c["tree"] for c in all_cases}
samples = json.load(open(f"{tmp}/in.json"))
lean = json.load(open(f"{tmp}/out.json"))
bad = 0
for name, strs in samples.items():
    rx = re.compile(cases[name][:-1] + r"\Z")  # ECMA $: only at the very end
    for s, got in zip(strs, lean[name]):
        want = rx.search(s) is not None
        if want != got:
            bad += 1
            print(f"FAIL {name}: Lean says {got} for {s!r}")
        if want != tree_matches(trees[name], s):
            bad += 1
            print(f"FAIL {name}: the reference tree matcher says {not want} for {s!r}")
total = sum(len(v) for v in samples.values())
print(f"{'ok  ' if not bad else 'FAIL'} fuzz: Lean, the tree matcher and the regex agree on {total - bad} of {total} strings")
sys.exit(1 if bad else 0)
PY
rm -rf "$tmp"
