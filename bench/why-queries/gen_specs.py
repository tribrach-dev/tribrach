"""Write the feature versions of the access and deploy specs.

Bench/src/<Name>.lean.in holds every version of one spec. Lines between
`--@ if <feature>` and `--@ end` (with an optional `--@ else`) are kept only
in versions that have that feature; `{{NS}}` and `{{NAME}}` become the
version's namespace and model name. Version 1 is the original spec.

usage: python gen_specs.py          (rewrites Bench/<Name><n>.lean)
       python gen_specs.py --check  (fails if any generated file is stale)
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

VERSIONS = {
    "Deploy": [[], ["tier0"], ["tier0", "depfreeze"], ["tier0", "depfreeze", "sensitive"]],
    "Access": [[], ["tempgrant"], ["tempgrant", "holiday"], ["tempgrant", "holiday", "quarantine"]],
}


def render(text, features, ns, name):
    out, stack = [], []  # stack of (feature on?, in else?)
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith("--@ if "):
            stack.append([s[len("--@ if "):] in features, False])
            continue
        if s == "--@ else":
            stack[-1][1] = True
            continue
        if s == "--@ end":
            stack.pop()
            continue
        if all(on != in_else for on, in_else in stack):
            out.append(line.replace("{{NS}}", ns).replace("{{NAME}}", name))
    assert not stack, "unclosed --@ if"
    return "".join(out)


def outputs():
    for base, versions in VERSIONS.items():
        text = (HERE / "Bench" / "src" / f"{base}.lean.in").read_text()
        for k, feats in enumerate(versions):
            suffix = "" if k == 0 else str(k + 1)
            yield (HERE / "Bench" / f"{base}{suffix}.lean",
                   render(text, feats, f"{base}{suffix}", f"{base.lower()}{suffix}"))


def main():
    stale = []
    for path, text in outputs():
        if "--check" in sys.argv:
            if not path.exists() or path.read_text() != text:
                stale.append(path.name)
        else:
            path.write_text(text)
    if stale:
        print("stale:", ", ".join(stale), "- run python gen_specs.py")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
