#!/bin/sh
# Export into out/ and compare with expected/ as JSON (key order and
# whitespace don't matter). Stamps are compared too: they must stay stable
# for this toolchain.
set -e
lake exe export out
python3 - <<'PY'
import json, pathlib, sys
failed = False
for name in ("counter.manifest.json", "counter.vectors.json"):
    got = json.loads(pathlib.Path("out", name).read_text())
    want = json.loads(pathlib.Path("expected", name).read_text())
    if got != want:
        failed = True
        print(f"FAIL {name} differs from expected/{name}; got:")
        print(json.dumps(got, indent=2))
    else:
        print(f"ok   {name}")
sys.exit(1 if failed else 0)
PY
