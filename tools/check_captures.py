"""Validate format goldens: everything in tests/<kind>/valid must pass and
everything in tests/<kind>/invalid must fail, for captures, feedback reports,
triage results, manifests and vectors. Also checks the committed outputs of
the feedback-sources and export-formats examples against their schemas."""

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
    for name in (
        "capture.schema.json",
        "report.schema.json",
        "triage.schema.json",
        "manifest.schema.json",
        "vectors.schema.json",
        "graph.schema.json",
        "refresh.schema.json",
    )
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
MANIFEST = validator("manifest.schema.json")
VECTORS = validator("vectors.schema.json")
GRAPH = validator("graph.schema.json")
REFRESH = validator("refresh.schema.json")


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


def manifest_problems(doc):
    errs = [e.message for e in MANIFEST.iter_errors(doc)]
    if errs:
        return errs
    seen = set()
    for l in doc["links"]:
        key = (l["lean"], l["owner"], l["symbol"])
        if key in seen:
            errs.append(f"link {key} appears twice")
        seen.add(key)
    return errs


def vectors_problems(doc):
    errs = [e.message for e in VECTORS.iter_errors(doc)]
    if errs:
        return errs
    ids = set()
    for c in doc["cases"]:
        if c["id"] in ids:
            errs.append(f"case id {c['id']} appears twice")
        ids.add(c["id"])
        if len(c["states"]) != len(c["ops"]):
            errs.append(f"case {c['id']} has {len(c['ops'])} operations but {len(c['states'])} states")
    return errs


def graph_problems(doc):
    errs = [e.message for e in GRAPH.iter_errors(doc)]
    if errs:
        return errs
    names = [n["name"] for n in doc["nodes"]]
    if len(set(names)) != len(names):
        errs.append("a node appears twice")
    for n in doc["nodes"]:
        for u in n["uses"]:
            if u not in names:
                errs.append(f"{n['name']} uses {u}, which isn't a node")
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


def check_exports():
    """The export example's committed outputs and the replay conformance
    vectors follow the manifest and vectors formats."""
    failed = False
    out = ROOT / "examples" / "export-formats" / "exported"
    docs = [
        ("export-formats/exported/counter.manifest.json", manifest_problems, json.loads((out / "counter.manifest.json").read_text())),
        ("export-formats/exported/counter.vectors.json", vectors_problems, json.loads((out / "counter.vectors.json").read_text())),
        ("export-formats/exported/tribrach.graph.json", graph_problems, json.loads((out / "tribrach.graph.json").read_text())),
        ("conformance/replay.json vectors", vectors_problems, json.loads((ROOT / "tests" / "conformance" / "replay.json").read_text())["vectors"]),
    ]
    for name, check, doc in docs:
        errs = check(doc)
        print(f"{'ok  ' if not errs else 'FAIL'} {name}{' (' + errs[0] + ')' if errs else ''}")
        failed |= bool(errs)
    return failed


def main():
    failed = check_goldens("captures", problems)
    failed |= check_goldens("reports", schema_only(REPORT))
    failed |= check_goldens("triage", schema_only(TRIAGE))
    failed |= check_goldens("manifests", manifest_problems)
    failed |= check_goldens("vectors", vectors_problems)
    failed |= check_goldens("graphs", graph_problems)
    failed |= check_goldens("refresh", schema_only(REFRESH))
    failed |= check_outputs()
    failed |= check_exports()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
