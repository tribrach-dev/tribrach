"""Reference implementation of the instrument conformance cases in
tests/conformance. Instruments must produce the same results in their own
language; this file shows the cases agree with each other and with the
schemas. Run: python tools/conformance.py"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "tests" / "conformance"
STAMP = re.compile(r"^[0-9a-f]{16}$")
PREFIX = "tribrach:"


def split_args(text):
    """Split on runs of spaces/tabs, keeping «...» groups whole."""
    args, cur, quoted = [], "", False
    for ch in text:
        if ch == "«":
            quoted = True
        elif ch == "»":
            quoted = False
        if ch in " \t" and not quoted:
            if cur:
                args.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        args.append(cur)
    return args


def parse_annotation(line):
    """One comment line (with its // marker) -> directive dict, error dict or None."""
    if not line.startswith("//"):
        return None
    body = line[2:]
    if not body.startswith(PREFIX):
        return None
    words = split_args(body[len(PREFIX):].rstrip())
    name, args = (words[0], words[1:]) if words and not body[len(PREFIX):].startswith((" ", "\t")) else ("", words)
    arity = {"link": 1, "stamp": 1, "pure": 0}
    if name not in arity:
        return {"error": "unknown-directive"}
    if len(args) < arity[name]:
        return {"error": "missing-argument"}
    if len(args) > arity[name]:
        return {"error": "extra-argument"}
    if name == "link":
        return {"directive": "link", "lean": args[0]}
    if name == "stamp":
        if not STAMP.match(args[0]):
            return {"error": "bad-stamp"}
        return {"directive": "stamp", "stamp": args[0]}
    return {"directive": "pure"}


def drift(owner, manifest, host):
    mine = [l for l in manifest if l["owner"] == owner]
    by_symbol = {(l["lean"], l["symbol"]): l for l in mine}
    names = {l["lean"] for l in mine}
    out, seen = [], set()
    for h in host:
        key = (h["lean"], h["symbol"])
        if key in by_symbol:
            seen.add(key)
            want = by_symbol[key]["stamp"]
            if "stamp" not in h:
                out.append({"lean": h["lean"], "symbol": h["symbol"], "outcome": "unstamped", "want": want})
            elif h["stamp"] != want:
                out.append({"lean": h["lean"], "symbol": h["symbol"], "outcome": "drift", "want": want})
            else:
                out.append({"lean": h["lean"], "symbol": h["symbol"], "outcome": "ok"})
        elif h["lean"] in names:
            want = sorted(l["symbol"] for l in mine if l["lean"] == h["lean"])[0]
            out.append({"lean": h["lean"], "symbol": h["symbol"], "outcome": "symbol-mismatch", "want": want})
        else:
            out.append({"lean": h["lean"], "symbol": h["symbol"], "outcome": "unknown"})
    for key, l in by_symbol.items():
        if key not in seen:
            out.append({"lean": l["lean"], "symbol": l["symbol"], "outcome": "missing"})
    return sorted(out, key=lambda f: (f["lean"], f["symbol"]))


def same(a, b):
    """JSON equality: key order ignored, numbers by value, bools aren't numbers."""
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def replay(vectors, host):
    out = []
    for case in vectors["cases"]:
        got = host[case["id"]]
        result = {"case": case["id"], "outcome": "ok"}
        for i, (op, want) in enumerate(zip(case["ops"], case["states"])):
            if not same(want, got[i]):
                result = {"case": case["id"], "outcome": "differs", "step": i + 1,
                          "op": op, "want": want, "got": got[i]}
                break
        out.append(result)
    return out


def report(label, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        print(f"     want {json.dumps(want)}\n     got  {json.dumps(got)}")
    return not ok


def main():
    failed = False
    ann = json.loads((CASES / "annotations.json").read_text())
    for c in ann["cases"]:
        failed |= report(f"annotations: {c['line']!r}", parse_annotation(c["line"]), c["expect"])
    dr = json.loads((CASES / "drift.json").read_text())
    for c in dr["cases"]:
        failed |= report(f"drift: {c['id']}", drift(dr["owner"], c["manifest"], c["host"]), c["expect"])
    rp = json.loads((CASES / "replay.json").read_text())
    failed |= report("replay: counter", replay(rp["vectors"], rp["host"]), rp["expect"])
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
