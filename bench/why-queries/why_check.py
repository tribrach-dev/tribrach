"""`./why check <model>`: does the code agree with the specification on many
generated inputs? Prints how many disagree and, for the first one, the input,
both answers and the specification's reasons.

usage (through ./why): ./why check <model> [--show N]

The engine path and the model's current spec name are passed by ./why. The
generated inputs live in check/<model>.json; the specification's expected
decisions for them are written to check/<model>-expected.json, so any case can
be replayed with run_tests.py or asked about with
`./why <model> --cases check/<model>-expected.json <case-id> ...`.
"""
import importlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main(argv):
    engine, spec_name, model = argv[:3]
    show = 1
    if argv[3:5] and argv[3] == "--show":
        show = int(argv[4])
    inputs = HERE / "check" / f"{model}.json"
    expected_path = HERE / "check" / f"{model}-expected.json"
    out = subprocess.run([engine, "expect", spec_name, str(inputs)], capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr.strip() or "the specification could not be evaluated")
        return 2
    expected_path.write_text(out.stdout)
    cases = json.loads(out.stdout)

    sys.path.insert(0, str(HERE / "host"))
    mod = importlib.import_module(model)
    bad = []
    for c in cases:
        try:
            got = mod.decide(c["input"])
        except Exception as e:  # a crash is a disagreement too
            got = f"error: {type(e).__name__}: {e}"
        if got != c["expected"]:
            bad.append((c, got))

    rel = expected_path.relative_to(HERE)
    print(f"Checked {len(cases)} generated inputs against the specification: "
          f"{len(bad)} disagree.")
    if not bad:
        return 0
    for c, got in bad[:show]:
        exp = c["expected"]
        print(f"\nFirst disagreement: {c['id']}" if show == 1 else f"\n{c['id']}")
        print(f"  input:              {json.dumps(c['input'])}")
        print(f"  specification says: {exp}")
        print(f"  code says:          {got}")
        missing = [d for d in exp if not isinstance(got, list) or d not in got]
        extra = [d for d in got if d not in exp] if isinstance(got, list) else []
        for d in missing:
            print(f"\nWhy the specification decides `{d}`:")
            r = subprocess.run([engine, spec_name, str(expected_path), c["id"], "why", *d.split()],
                               capture_output=True, text=True)
            print(r.stdout.rstrip())
        for d in extra:
            print(f"\nWhy the specification does not decide `{d}`:")
            r = subprocess.run([engine, spec_name, str(expected_path), c["id"], "whynot", *d.split()],
                               capture_output=True, text=True)
            print(r.stdout.rstrip())
    rest = [c["id"] for c, _ in bad[show:show + 12]]
    if rest:
        print(f"\nOther disagreeing cases: {', '.join(rest)}{' ...' if len(bad) > show + 12 else ''}")
    print(f"\nExpected decisions for all of them are in {rel}: "
          f"`python3 run_tests.py {model} {rel}` replays them, and "
          f"`./why {model} --cases {rel} <case-id>` explains one.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
