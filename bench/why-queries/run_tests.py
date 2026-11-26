"""Replay the test vectors against the host code and report mismatches.

usage: python run_tests.py              (all models in tests/)
       python run_tests.py FILE.json    (your own cases, for the model in tests/)

A case without expected decisions is only run, and what the code decides
is printed.
"""
import importlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name):
    sys.path.insert(0, str(HERE / "host"))
    return importlib.import_module(name)


def main():
    failed = 0
    total = 0
    models = sorted(v.stem for v in (HERE / "tests").glob("*.json"))
    if len(sys.argv) > 1:
        files = [(models[0], Path(a)) for a in sys.argv[1:]]
    else:
        files = [(m, HERE / "tests" / f"{m}.json") for m in models]
    for name, vec in files:
        mod = load(name)
        for case in json.loads(vec.read_text()):
            got = mod.decide(case["input"])
            if "expected" not in case:
                print(f"RAN  {name} {case['id']}: the code decides {got}")
                continue
            total += 1
            if got != case["expected"]:
                failed += 1
                print(f"FAIL {name} {case['id']}")
                print(f"  input:    {json.dumps(case['input'])}")
                print(f"  expected: {case['expected']}")
                print(f"  got:      {got}")
    print(f"{total - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
