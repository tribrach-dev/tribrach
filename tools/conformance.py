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


def matches(regex, s):
    """ECMA-262 anchoring: Python's $ also matches before a final newline,
    so the closing $ becomes \\Z."""
    assert regex.endswith("$")
    return re.search(regex[:-1] + r"\Z", s) is not None


def _in_set(items, c):
    return any(c == it if isinstance(it, str) else it[0] <= c <= it[1] for it in items)


def _banned(ban, rest):
    if "startsWith" in ban:
        return rest.startswith(ban["startsWith"])
    return ban["segment"] in rest.split(ban["sep"])


def tree_steps(t, s, i):
    """Every position the pattern tree can stop at, starting from s[i]."""
    if "lit" in t:
        return {i + len(t["lit"])} if s.startswith(t["lit"], i) else set()
    if "set" in t or "notSet" in t:
        neg = "notSet" in t
        return {i + 1} if i < len(s) and _in_set(t["notSet" if neg else "set"], s[i]) != neg else set()
    if "seq" in t:
        front = {i}
        for r in t["seq"]:
            front = {k for j in front for k in tree_steps(r, s, j)}
        return front
    if "alt" in t:
        return {k for r in t["alt"] for k in tree_steps(r, s, i)}
    if "rep" in t:
        lo, hi = t["min"], t["max"]
        out, front, n = set(), {i}, 0
        while front:
            if n >= lo:
                out |= front
            if hi is not None and n == hi:
                break
            # A round that consumes nothing adds nothing once min is met.
            front = {k for j in front for k in tree_steps(t["rep"], s, j) if k > j or n < lo}
            n += 1
        return out
    if "without" in t:
        return set() if any(_banned(b, s[i:]) for b in t["bans"]) else tree_steps(t["without"], s, i)
    raise ValueError(f"unknown pattern tree node {t}")


def tree_matches(tree, s):
    """The generic matcher instruments implement over patterns.json trees."""
    return len(s) in tree_steps(tree, s, 0)


class WireError(Exception):
    pass


def parse_wire(text):
    """Strict JSON: one value, no duplicate keys, no NaN; numbers kept exact."""
    import decimal

    def pairs(kvs):
        out = {}
        for k, v in kvs:
            if k in out:
                raise WireError(f"duplicate key {k!r}")
            out[k] = v
        return out

    def no_constant(name):
        raise WireError(f"{name} is not JSON")

    try:
        return json.loads(text, object_pairs_hook=pairs, parse_float=decimal.Decimal,
                          parse_constant=no_constant)
    except ValueError as e:
        raise WireError(str(e))


INSTANT = None  # the instant regex, read from patterns.json in main()
DECIMAL = None


def read_instant(s):
    import datetime
    if not matches(INSTANT, s):
        raise WireError("not an instant")
    y, mo, d, h, mi, se = (int(s[a:b]) for a, b in ((0, 4), (5, 7), (8, 10), (11, 13), (14, 16), (17, 19)))
    t = datetime.datetime(y, mo, 1, h, mi, se) + datetime.timedelta(days=d - 1)  # 02-30 rolls over
    if s[19] != "Z":
        off = datetime.timedelta(hours=int(s[20:22]), minutes=int(s[23:25]))
        t = t - off if s[19] == "+" else t + off
    return f"{t.year:04d}-{t:%m-%dT%H:%M:%S}Z"


def whole(v):
    import decimal
    if isinstance(v, bool) or not isinstance(v, (int, decimal.Decimal)):
        raise WireError("want a whole number")
    if isinstance(v, decimal.Decimal):
        if v != v.to_integral_value():
            raise WireError("not whole")
        v = int(v)
    return v


def read_wire(schema, v):
    """Read v as the schema says and give back what a codec writes."""
    if "const" in schema:
        if v != schema["const"] or isinstance(v, bool):
            raise WireError("not the constant")
        return v
    if "enum" in schema:
        if not isinstance(v, str) or v not in schema["enum"]:
            raise WireError("not in the enum")
        return v
    if "oneOf" in schema:
        got = []
        for alt in schema["oneOf"]:
            try:
                got.append(read_wire(alt, v))
            except WireError:
                pass
        if len(got) != 1:
            raise WireError("not exactly one alternative")
        return got[0]
    t = schema["type"]
    if t == "boolean":
        if not isinstance(v, bool):
            raise WireError("want a boolean")
        return v
    if t == "integer":
        n = whole(v)
        if n < schema.get("minimum", n) or n > schema.get("maximum", n) or n % schema.get("multipleOf", 1):
            raise WireError("out of bounds")
        return n
    if t == "string":
        if not isinstance(v, str):
            raise WireError("want a string")
        pat = schema.get("pattern")
        if pat == DECIMAL:
            bounds = schema.get("x-tribrach", {})
            if not matches(pat, v) or not bounds.get("minimum", int(v)) <= int(v) <= bounds.get("maximum", int(v)):
                raise WireError("not a decimal in bounds")
            return str(int(v))
        if pat == INSTANT:
            return read_instant(v)
        if not schema.get("minLength", 0) <= len(v) <= schema.get("maxLength", len(v)):
            raise WireError("wrong length")
        if pat is not None and not matches(pat, v):
            raise WireError("pattern")
        return v
    if t == "array":
        if not isinstance(v, list) or not schema.get("minItems", 0) <= len(v) <= schema.get("maxItems", len(v)):
            raise WireError("want an array of the right length")
        return [read_wire(schema["items"], x) for x in v]
    if t == "object":
        if not isinstance(v, dict):
            raise WireError("want an object")
        props = schema["properties"]
        if any(k not in props for k in v) or any(k not in v for k in schema.get("required", [])):
            raise WireError("keys")
        return {k: read_wire(props[k], x) for k, x in v.items()}
    raise ValueError(f"schema not covered: {schema}")


def wire(schema, text):
    try:
        return {"output": read_wire(schema, parse_wire(text))}
    except WireError:
        return {"error": True}


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
    pt = json.loads((CASES / "patterns.json").read_text())
    for c in pt["cases"]:
        for want, key in ((True, "accept"), (False, "reject")):
            for s in c[key]:
                label = f"patterns: {c['name']} {key}s {s!r}"
                failed |= report(label + " (regex)", matches(c["regex"], s), want)
                failed |= report(label + " (tree)", tree_matches(c["tree"], s), want)
    global INSTANT, DECIMAL
    INSTANT = next(c["regex"] for c in pt["cases"] if c["name"] == "instant")
    DECIMAL = next(c["regex"] for c in pt["cases"] if c["name"] == "decimal")
    wr = json.loads((CASES / "wire.json").read_text())
    for c in wr["cases"]:
        want = {k: c[k] for k in ("output", "error") if k in c}
        failed |= report(f"wire: {c['id']}", wire(c["schema"], c["input"]), want)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
