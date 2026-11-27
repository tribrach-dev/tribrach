"""Command-line entry point: `python -m deploy.cli request.json`."""
import json
import sys

from .gate import Gate


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print("usage: cli.py REQUEST.json [...]", file=sys.stderr)
        return 2
    gate = Gate.default()
    code = 0
    for path in argv:
        with open(path) as f:
            v = gate.evaluate(json.load(f))
        print(f"{path}: {' '.join(v.decisions()) or 'blocked'}")
        for b in v.blockers:
            print(f"  - {b}")
        if v.blockers:
            code = 1
    return code


if __name__ == "__main__":
    sys.exit(main())
