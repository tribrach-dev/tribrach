"""Validate capture goldens: everything in tests/captures/valid must pass,
everything in tests/captures/invalid must fail."""

import json
import pathlib
import sys

import jsonschema

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = json.loads((ROOT / "schema" / "capture.schema.json").read_text())
VALIDATOR = jsonschema.Draft202012Validator(
    SCHEMA, format_checker=jsonschema.FormatChecker()
)


def problems(capture):
    """Schema errors plus the rules JSON Schema can't express."""
    errs = [e.message for e in VALIDATOR.iter_errors(capture)]
    if errs:
        return errs
    prev_end = 0
    for r in capture["ranges"]:
        if r["end"] < r["start"]:
            errs.append(f"range {r} ends before it starts")
        if r["start"] <= prev_end:
            errs.append(f"range {r} overlaps or is out of order")
        prev_end = r["end"]
    return errs


def main():
    failed = False
    for kind, should_pass in (("valid", True), ("invalid", False)):
        for path in sorted((ROOT / "tests" / "captures" / kind).glob("*.json")):
            errs = problems(json.loads(path.read_text()))
            ok = (not errs) == should_pass
            label = "ok  " if ok else "FAIL"
            detail = "" if should_pass else f" ({errs[0] if errs else 'accepted'})"
            print(f"{label} {kind}/{path.name}{detail}")
            failed |= not ok
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
