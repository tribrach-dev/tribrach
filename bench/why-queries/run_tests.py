"""Replay the test vectors against the host code and report mismatches.

usage: python run_tests.py            (all models in tests/)
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
    for vec in sorted((HERE / "tests").glob("*.json")):
        name = vec.stem
        mod = load(name)
        for case in json.loads(vec.read_text()):
            total += 1
            got = mod.decide(case["input"])
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
