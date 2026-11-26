#!/bin/sh
# CI has already run `lake build`, which compiled CounterExport and rewrote
# exported/. Check that:
#  1. the committed files are exactly what the build exports (not stale);
#  2. the refresh report is empty, since nothing changed since the commit;
#  3. after a simulated upstream change, the refresh report names the links
#     to re-check and the definition that caused it.
set -e

if [ -n "$(git status --porcelain -- exported/)" ]; then
  echo "FAIL exported/ is stale; the build wrote:"
  git status --porcelain -- exported/
  for f in exported/*.json; do echo "== $f"; cat "$f"; done
  exit 1
fi
echo "ok   exported/ matches the build"

python3 - <<'PY'
import json, sys
r = json.load(open("exported/tribrach.refresh.json"))
if r["items"] or r["changed"]:
    print("FAIL refresh should be empty:", json.dumps(r, indent=2)); sys.exit(1)
print("ok   nothing to refresh")
PY

# Pretend the last export saw another Counter.CounterOp and older stamps.
python3 - <<'PY'
import json
g = json.load(open("exported/tribrach.graph.json"))
for n in g["nodes"]:
    if n["name"] == "Counter.CounterOp":
        n["hash"] = "1111111111111111"
json.dump(g, open("exported/tribrach.graph.json", "w"))
m = json.load(open("exported/counter.manifest.json"))
for l in m["links"]:
    l["stamp"] = "2222222222222222"
json.dump(m, open("exported/counter.manifest.json", "w"))
PY
echo "-- recompile" >> CounterExport.lean
lake build CounterExport
python3 - <<'PY'
import json, sys
r = json.load(open("exported/tribrach.refresh.json"))
items = r["items"]
ok = (r["changed"] == ["Counter.CounterOp"]
      and [i["owner"] for i in items] == ["tribrach.go", "tribrach.swift"]
      and all(i["status"] == "changed" and i["from"] == "2222222222222222"
              and i["because"] == ["Counter.CounterOp"] for i in items))
print(("ok  " if ok else "FAIL") + " refresh after an upstream change:")
print(json.dumps(r, indent=2))
sys.exit(0 if ok else 1)
PY
git checkout -- CounterExport.lean exported/
lake build CounterExport
