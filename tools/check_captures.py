"""Validate format goldens: everything in tests/<kind>/valid must pass and
everything in tests/<kind>/invalid must fail, for captures, feedback reports
and triage results. Also checks the committed outputs of the
feedback-sources example against the report and triage schemas."""

import json
import pathlib
import sys

import jsonschema

from referencing import Registry, Resource

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_schema(name):
    return json.loads((ROOT / "schema" / name).read_text())


SCHEMAS = {
    name: load_schema(name)
    for name in ("capture.schema.json", "report.schema.json", "triage.schema.json")
}
REGISTRY = Registry().with_resources(
    (s["$id"], Resource.from_contents(s)) for s in SCHEMAS.values()
)


def validator(name):
    return jsonschema.Draft202012Validator(
        SCHEMAS[name], registry=REGISTRY, format_checker=jsonschema.FormatChecker()
    )


VALIDATOR = validator("capture.schema.json")
REPORT = validator("report.schema.json")
TRIAGE = validator("triage.schema.json")


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


def schema_only(v):
    return lambda doc: [e.message for e in v.iter_errors(doc)]


def check_goldens(folder, check):
    failed = False
    for kind, should_pass in (("valid", True), ("invalid", False)):
        for path in sorted((ROOT / "tests" / folder / kind).glob("*.json")):
            errs = check(json.loads(path.read_text()))
            ok = (not errs) == should_pass
            label = "ok  " if ok else "FAIL"
            detail = "" if should_pass else f" ({errs[0] if errs else 'accepted'})"
            print(f"{label} {folder}/{kind}/{path.name}{detail}")
            failed |= not ok
    return failed


def check_outputs():
    """The feedback-sources example's committed outputs follow the schemas."""
    failed = False
    expected = ROOT / "examples" / "feedback-sources" / "expected"
    docs = [("reports.json", REPORT, d) for d in json.loads((expected / "reports.json").read_text())]
    for line in (expected / "triage.jsonl").read_text().splitlines():
        docs.append(("triage.jsonl", TRIAGE, json.loads(line)))
    for name, v, doc in docs:
        errs = [e.message for e in v.iter_errors(doc)]
        label = "ok  " if not errs else "FAIL"
        ident = doc.get("id") or doc.get("report")
        print(f"{label} feedback-sources/expected/{name} {ident}{' (' + errs[0] + ')' if errs else ''}")
        failed |= bool(errs)
    return failed


def main():
    failed = check_goldens("captures", problems)
    failed |= check_goldens("reports", schema_only(REPORT))
    failed |= check_goldens("triage", schema_only(TRIAGE))
    failed |= check_outputs()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
