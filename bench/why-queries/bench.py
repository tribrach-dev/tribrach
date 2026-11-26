"""Benchmark: diagnosing planted bugs with and without why-queries.

Subcommands:

  python bench.py check
      The clean host code passes every vector, and each planted fault fails
      at least one.
  python bench.py run --model M --tasks T1,T2 --arms baseline,logic --reps N
      For each task, arm and repeat, build a fresh task folder and run one
      headless Claude Code session in it (`claude -p`). Appends one line per
      run to results/runs-<suite>-<model>.jsonl.
  python bench.py summarize
      Writes results/RESULTS.md from results/runs.jsonl.

Tasks are the planted faults in faults.json plus the questions in
questions.json. See README.md for the method.
"""
import argparse
import datetime as dt
import difflib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORK = Path(os.environ.get("WHY_BENCH_WORK", "/tmp/why-bench"))
# The why tool is installed outside the task folders and the repository, so
# a session can't wander from it to the answer key.
ENGINE = Path(os.environ.get("WHY_BENCH_ENGINE", "/opt/why-bench/why"))
RESULTS = HERE / "results"

SPEC = {"irrigation": "Irrigation", "library": "Library", "notify": "Notify",
        "access": "Access", "deploy": "Deploy"}
DESCRIBE = {
    "irrigation": "garden irrigation controller (which valves to open this hour)",
    "library": "library lending desk (which requested items a member may take home)",
    "notify": "notification service (which channels an event goes out on)",
    "access": "building access service (what happens when someone taps a badge at a door)",
    "deploy": "deploy gate (whether and how a change ships)",
}

TOOLS = "Bash,Read,Grep,Glob,Write,Edit"


SUITES = {
    # One module per model, about 40-60 lines: the whole program fits in one read.
    "small": {"host": "host", "faults": "faults.json"},
    # The same logic spread over a package of 7-9 modules (160-290 lines),
    # next to code that has nothing to do with the decision.
    "large": {"host": "host_large", "faults": "faults_large.json"},
    # User reports against bigger packages (430-720 lines) with deeper specs.
    # Some reports describe a real bug; in others the code is right and the
    # user's expectation is wrong. No test fails: the report is the evidence.
    "hard": {"host": "host_hard", "reports": "tasks_hard.json"},
    # The same packages, but the session must fix the code (or leave it alone
    # when the user is wrong), and the fix is graded on hidden vectors. Reports
    # are vague and name no test case; one fault needs edits in two places.
    "fix": {"host": "host_hard", "fixes": "tasks_fix.json"},
}


def faults(suite):
    if "faults" not in SUITES[suite]:
        return []
    return json.loads((HERE / SUITES[suite]["faults"]).read_text())


def reports(suite):
    """Report-style tasks (the `reports` or `fixes` file of a suite)."""
    key = "reports" if "reports" in SUITES[suite] else "fixes" if "fixes" in SUITES[suite] else None
    if key is None:
        return []
    return [{**t, "fix": key == "fixes"} for t in json.loads((HERE / SUITES[suite][key]).read_text())]


def is_report_suite(suite):
    return "reports" in SUITES[suite] or "fixes" in SUITES[suite]


def suite_models(suite):
    return sorted({t["model"] for t in reports(suite)}) if is_report_suite(suite) else \
        ["irrigation", "library", "notify"]


def questions():
    return json.loads((HERE / "questions.json").read_text())


def tasks(suite):
    if is_report_suite(suite):
        return {t["id"]: t for t in reports(suite)}
    return {t["id"]: t for t in faults(suite) + questions()}


def host_tree(model, suite):
    """The clean host code for a model, as {path under host/: source}."""
    root = HERE / SUITES[suite]["host"]
    if (root / f"{model}.py").exists():
        return {f"{model}.py": (root / f"{model}.py").read_text()}
    return {f"{model}/{p.name}": p.read_text() for p in sorted((root / model).glob("*.py"))}


def entry(model, suite):
    """How the prompt names the implementation."""
    if suite == "small":
        return f"host/{model}.py is the implementation."
    return f"host/{model}/ is the implementation, a Python package; its `decide` function is the entry point the tests call."


def fault_file(fault):
    if "edits" in fault:
        return fault["edits"][0]["file"]
    return fault.get("file", f"{fault['model']}.py")


def plant(fault, suite):
    """Return the host tree with the fault planted, and the 1-based lines
    that hold the fault in fault_file(fault)."""
    tree = host_tree(fault["model"], suite)
    if "edits" in fault:  # several edits; lines are where each edit starts
        tree, lines = dict(tree), set()
        for e in fault["edits"]:
            src = tree[e["file"]]
            assert src.count(e["find"]) == 1, f"{fault['id']}: find text must occur once"
            if e["file"] == fault_file(fault):
                lines.add(src[: src.index(e["find"])].count("\n") + 1)
            tree[e["file"]] = src.replace(e["find"], e["replace"])
        return tree, sorted(lines)
    path = fault_file(fault)
    src = tree[path]
    assert src.count(fault["find"]) == 1, f"{fault['id']}: find text must occur once"
    bad = src.replace(fault["find"], fault["replace"])
    marks = fault.get("line_of", fault["replace"])
    marks = [marks] if isinstance(marks, str) else marks
    lines = set()
    for m in marks:
        assert bad.count(m) == 1, f"{fault['id']}: line_of {m!r} must occur once"
        lines.add(bad[: bad.index(m)].count("\n") + 1)
    return {**tree, path: bad}, sorted(lines)


def vectors(model):
    return json.loads((HERE / "vectors" / f"{model}.json").read_text())


def host_decide(tree, model, inputs):
    """Run a host tree's `decide` on each input, in a fresh interpreter.
    An input whose call raises gets the string "error: ..."."""
    d = WORK / "check" / uuid.uuid4().hex[:12]
    for rel, src in tree.items():
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_text(src)
    code = (f"import json, sys; sys.path.insert(0, {str(d)!r}); import {model} as m\n"
            "def one(i):\n"
            "    try:\n        return m.decide(i)\n"
            "    except Exception as e:\n        return 'error: ' + repr(e)\n"
            "print(json.dumps([one(i) for i in json.load(sys.stdin)]))")
    try:
        out = subprocess.run([sys.executable, "-c", code], input=json.dumps(inputs),
                             capture_output=True, text=True, check=True, timeout=300).stdout
        return json.loads(out)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        return [f"error: {type(e).__name__}"] * len(inputs)
    finally:
        shutil.rmtree(d, ignore_errors=True)


_QUIET = {}


def quiet_vectors(model, suite):
    """For report suites: the vectors that no planted fault changes, so that
    the tests pass whichever fault is planted and the report stays the only
    evidence."""
    if (model, suite) not in _QUIET:
        cases = vectors(model)
        keep = [True] * len(cases)
        for t in reports(suite):
            if t["model"] == model and t["verdict"] == "bug":
                tree, _ = plant(t, suite)
                got = host_decide(tree, model, [c["input"] for c in cases])
                keep = [k and g == c["expected"] for k, g, c in zip(keep, got, cases)]
        _QUIET[(model, suite)] = [c for k, c in zip(keep, cases) if k]
    return _QUIET[(model, suite)]


def write_workspace(run_dir, model, tree, cases):
    if run_dir.exists():
        shutil.rmtree(run_dir)
    for d in ("host", "spec", "tests"):
        (run_dir / d).mkdir(parents=True)
    for rel, src in tree.items():
        (run_dir / "host" / rel).parent.mkdir(parents=True, exist_ok=True)
        (run_dir / "host" / rel).write_text(src)
    shutil.copy(HERE / "Bench" / f"{SPEC[model]}.lean", run_dir / "spec")
    shutil.copy(HERE / "run_tests.py", run_dir)
    (run_dir / "tests" / f"{model}.json").write_text(json.dumps(cases, indent=1) + "\n")


def failing(model, tree, cases):
    d = WORK / "check" / uuid.uuid4().hex[:12]
    write_workspace(d, model, tree, cases)
    out = subprocess.run([sys.executable, "run_tests.py"], cwd=d, capture_output=True, text=True).stdout
    shutil.rmtree(d)
    return re.findall(r"^FAIL \S+ (\S+)", out, re.M)


def spec_expect(model, inputs):
    """Decisions from the specification, using the locally built engine."""
    local = HERE / ".lake" / "build" / "bin" / "why"
    d = WORK / "check" / uuid.uuid4().hex[:12]
    d.mkdir(parents=True)
    (d / "in.json").write_text(json.dumps([{"id": str(i), "input": x} for i, x in enumerate(inputs)]))
    out = subprocess.run([str(local if local.exists() else ENGINE), "expect", model, str(d / "in.json")],
                         capture_output=True, text=True, check=True).stdout
    shutil.rmtree(d)
    return [c["expected"] for c in json.loads(out)]


def hidden_vectors(model):
    return json.loads((HERE / "vectors" / f"hidden-{model}.json").read_text())


def check_fixes(suite):
    """Clean code passes the visible and hidden vectors; each fault passes
    the visible ones its session sees but fails hidden ones; for a fault in
    several places, every partial fix still fails hidden ones."""
    ok = True
    for model in suite_models(suite):
        hid = hidden_vectors(model)
        got = host_decide(host_tree(model, suite), model, [c["input"] for c in hid])
        bad = sum(g != c["expected"] for g, c in zip(got, hid))
        print(f"{suite} clean {model}: {bad} of {len(hid)} hidden failing; "
              f"{len(quiet_vectors(model, suite))} visible vectors")
        ok &= not bad
    for t in reports(suite):
        if t["verdict"] != "bug":
            print(f"{suite} {t['id']} (no_bug)")
            continue
        m, hid = t["model"], hidden_vectors(t["model"])
        variants = [("fault", t["edits"])]
        if len(t["edits"]) > 1:
            variants += [(f"only edit {i + 1}", [e]) for i, e in enumerate(t["edits"])]
        for label, edits in variants:
            tree, lines = plant({**t, "edits": edits}, suite)
            got = host_decide(tree, m, [c["input"] for c in hid])
            bad = sum(g != c["expected"] for g, c in zip(got, hid))
            vis = failing(m, tree, quiet_vectors(m, suite))
            good = bad > 0 and not vis
            print(f"{suite} {t['id']} {label}: {fault_file(t)} lines {lines}, {bad} hidden failing, "
                  f"{len(vis)} visible failing" + ("" if good else "  <-- PROBLEM"))
            ok &= good
    return ok


def check_reports(suite):
    ok = True
    for model in suite_models(suite):
        quiet = quiet_vectors(model, suite)
        fails = failing(model, host_tree(model, suite), vectors(model))
        print(f"{suite} clean {model}: {len(fails)} of {len(vectors(model))} failing; "
              f"{len(quiet)} vectors that no fault changes")
        ok &= not fails
    for t in reports(suite):
        m, case = t["model"], t["case"]
        want = spec_expect(m, [case["input"]])[0]
        clean = host_decide(host_tree(m, suite), m, [case["input"]])[0]
        line = f"{suite} {t['id']} ({t['verdict']}): spec {want}, clean {clean}"
        good = clean == want
        if t["verdict"] == "bug":
            tree, lines = plant(t, suite)
            bad = host_decide(tree, m, [case["input"]])[0]
            fails = failing(m, tree, quiet_vectors(m, suite))
            line += f", with fault {bad} ({fault_file(t)} lines {lines}), {len(fails)} tests failing"
            good &= bad != want and not fails
        print(line + ("" if good else "  <-- PROBLEM"))
        ok &= good
    return ok


def cmd_check(args):
    ok = True
    for suite in SUITES:
        if "reports" in SUITES[suite]:
            ok &= check_reports(suite)
            continue
        if "fixes" in SUITES[suite]:
            ok &= check_fixes(suite)
            continue
        for model in suite_models(suite):
            fails = failing(model, host_tree(model, suite), vectors(model))
            print(f"{suite} clean {model}: {len(fails)} failing")
            ok &= not fails
        for f in faults(suite):
            tree, lines = plant(f, suite)
            fails = failing(f["model"], tree, vectors(f["model"]))
            print(f"{suite} {f['id']}: {fault_file(f)} lines {lines}, failing {fails}")
            ok &= bool(fails)
        for q in questions():
            fails = failing(q["model"], host_tree(q["model"], suite), vectors(q["model"]) + [q["case"]])
            print(f"{suite} {q['id']}: {len(fails)} failing")
            ok &= not fails
    return 0 if ok else 1


# ---------------------------------------------------------------- prompts

BUG_PROMPT = """You are debugging a small {describe}.

- {entry}
- spec/{Spec}.lean is its specification (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide).
- tests/{model}.json holds test vectors; their expected decisions come from the specification.

`python3 run_tests.py` reports failures. There is exactly one root cause, somewhere in the code under host/.
{tool}
Find the root cause. Do not change any file except answer.json. When you are confident, write answer.json in this directory:

{{"file": "host/<path of the file>", "line": <line number of the faulty code>, "cause": "<one sentence>"}}

Work only inside this directory, and stop once answer.json is written."""

QUESTION_PROMPT = """You are helping with a small {describe}.

- {entry}
- spec/{Spec}.lean is its specification (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide).
- tests/{model}.json holds test vectors; their expected decisions come from the specification. Case {case_id} is the situation below.
{tool}
Question: {question}

Answer from the specification. Do not change any file except answer.json. When you are confident, write answer.json in this directory:

{answer_shape}

Work only inside this directory, and stop once answer.json is written."""

REPORT_PROMPT = """You are on call for a {describe}.

- {entry}
- spec/{Spec}.lean is its specification (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide). The specification is the source of truth.
- tests/{model}.json holds test vectors; their expected decisions come from the specification. `python3 run_tests.py` replays them (they all pass) and prints what the code decides for case {case_id}, which has no expected decisions.

A user reported this; case {case_id} in tests/{model}.json is the exact situation:

> {report}

Either the code under host/ has a bug (it decides differently from the specification), or the code is right and the user's expectation is wrong.
{tool}
Find out which. Do not change any file except answer.json. When you are confident, write answer.json in this directory:

{{"verdict": "bug" or "no_bug", "file": "host/<path of the faulty file>" or null, "line": <line number of the faulty code> or null, "cause": "<one sentence: the faulty code, or the condition that decides the case>"}}

Work only inside this directory, and stop once answer.json is written."""

FIX_PROMPT = """You are on call for a {describe}.

- {entry}
- spec/{Spec}.lean is its specification (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide). The specification is the source of truth.
- tests/{model}.json holds test vectors; their expected decisions come from the specification. `python3 run_tests.py` replays them, and they all pass. `python3 run_tests.py <file.json>` replays a file of your own in the same format (cases without "expected" are only run, and the code's decisions printed).

A user reported:

> {report}

Either the code under host/ disagrees with the specification, or the code is right and the user's expectation is wrong. If the code is wrong, fix it under host/ so that it agrees with the specification for every input, not only the reported situation: hidden tests will check. If the code is right, leave host/ unchanged. Do not change spec/, tests/ or run_tests.py; you may create other files.
{tool}
When you are done, write answer.json in this directory:

{{"verdict": "bug" or "no_bug", "files": [<paths under host/ that you changed>], "cause": "<one sentence: what was wrong, or the condition that decides the reported situation>"}}

Work only inside this directory, and stop once answer.json is written."""

FIX_WHY_TOOL = """
You also have `./why`, which answers questions from the specification for any case:

- `./why <case-id>`: the expected decisions for that case, each with its why tree (the rules and facts that produce it).
- `./why <case-id> whynot <decision...>`: why a decision does not follow, for example `./why {example}`.
- `./why <case-id> why <predicate> [args...]`: why any fact holds (or, if it doesn't, why not).
- `./why <case-id> facts`: the facts the specification's `encode` step produces from that case's input.
- `./why --cases <file.json> <case-id> ...`: the same, for a case in a file of your own (same format as tests/, "expected" not needed).

Asking `./why` about the reported situation is usually the quickest way to see which conditions decide it.
"""

WHY_TOOL = """
You also have `./why`, which answers questions from the specification for any test case:

- `./why <case-id>`: the expected decisions for that case, each with its why tree (the rules and facts that produce it).
- `./why <case-id> whynot <decision...>`: why a decision does not follow, for example `./why {example}`.
- `./why <case-id> why <predicate> [args...]`: why any fact holds (or, if it doesn't, why not).
- `./why <case-id> facts`: the facts the specification's `encode` step produces from that case's input.

Asking `./why` about {which} is usually the quickest way to see which conditions decide it.
"""

EXAMPLES = {"irrigation": "irr-01 whynot water lawn", "library": "lib-01 whynot lend m1 i1",
            "notify": "ntf-01 whynot deliver push", "access": "acc-01 whynot open d-office-2",
            "deploy": "dep-01 whynot deploy payments"}


def prompt_for(task, arm, suite):
    model = task["model"]
    which = "the reported case" if "report" in task else "a failing case"
    tool = WHY_TOOL.format(example=EXAMPLES[model], which=which) if arm == "logic" else ""
    common = dict(describe=DESCRIBE[model], model=model, Spec=SPEC[model], tool=tool,
                  entry=entry(model, suite))
    if task.get("fix"):
        first = quiet_vectors(model, suite)[0]["id"]  # an example id that is in tests/
        example = " ".join([first] + EXAMPLES[model].split()[1:])
        tool = FIX_WHY_TOOL.format(example=example) if arm == "logic" else ""
        return FIX_PROMPT.format(report=task["report"], **{**common, "tool": tool})
    if "report" in task:
        return REPORT_PROMPT.format(case_id=task["case"]["id"], report=task["report"], **common)
    if "question" in task:
        shape = json.dumps({k: "<one sentence>" for k in task["grade"]})
        return QUESTION_PROMPT.format(case_id=task["case"]["id"], question=task["question"],
                                      answer_shape=shape, **common)
    return BUG_PROMPT.format(**common)


def build(task, arm, suite, run_dir):
    model = task["model"]
    if task.get("fix"):
        tree = plant(task, suite)[0] if task["verdict"] == "bug" else host_tree(model, suite)
        cases = quiet_vectors(model, suite)
    elif "report" in task:
        tree = plant(task, suite)[0] if task["verdict"] == "bug" else host_tree(model, suite)
        cases = quiet_vectors(model, suite) + [task["case"]]
    elif "question" in task:
        tree, cases = host_tree(model, suite), vectors(model) + [task["case"]]
    else:
        tree, _ = plant(task, suite)
        cases = vectors(model)
    write_workspace(run_dir, model, tree, cases)
    if arm == "logic":
        w = run_dir / "why"
        if task.get("fix"):
            w.write_text(f'#!/bin/sh\ncases="$(dirname "$0")/tests/{model}.json"\n'
                         f'if [ "$1" = "--cases" ]; then cases="$2"; shift 2; fi\n'
                         f'exec "{ENGINE}" {model} "$cases" "$@"\n')
        else:
            w.write_text(f'#!/bin/sh\nexec "{ENGINE}" {model} "$(dirname "$0")/tests/{model}.json" "$@"\n')
        w.chmod(0o755)


# ---------------------------------------------------------------- grading

def grade_fix(task, suite, run_dir):
    """Fix tasks: replay the hidden vectors against the session's host/ and
    compare it with the code the session was given."""
    model = task["model"]
    given = plant(task, suite)[0] if task["verdict"] == "bug" else host_tree(model, suite)
    root = run_dir / "host"
    final = {str(p.relative_to(root)): p.read_text(errors="replace")
             for p in sorted(root.rglob("*.py")) if "__pycache__" not in p.parts}
    changed = sorted(k for k in set(given) | set(final) if given.get(k) != final.get(k))
    diff_lines = sum(1 for k in changed for l in difflib.unified_diff(
        given.get(k, "").splitlines(), final.get(k, "").splitlines(), lineterm="", n=0)
        if l[:1] in "+-" and not l.startswith(("+++", "---")))
    hid = hidden_vectors(model)
    got = host_decide(final, model, [c["input"] for c in hid])
    failed = [c["id"] for g, c in zip(got, hid) if g != c["expected"]]
    p = run_dir / "answer.json"
    try:
        ans = json.loads(p.read_text()) if p.exists() else None
    except json.JSONDecodeError:
        ans = None
    return {"hidden_failed": len(failed), "hidden_failed_ids": failed[:20], "changed_files": changed,
            "diff_lines": diff_lines, **grade_answer(task, suite, ans, hidden_failed=len(failed))}


def grade(task, suite, run_dir):
    if task.get("fix"):
        return grade_fix(task, suite, run_dir)
    p = run_dir / "answer.json"
    if not p.exists():
        return {"correct": False, "answer": None, "why": "no answer.json"}
    try:
        ans = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        return {"correct": False, "answer": None, "why": f"answer.json is not JSON: {e}"}
    return grade_answer(task, suite, ans)


def grade_answer(task, suite, ans, hidden_failed=None):
    """Bug tasks: correct when the answer names the planted file and its cause
    matches the fault's `cause_pattern`. The line number is graded separately
    (`line_ok`, within one line of the planted lines), because sessions often
    miscount lines when they print several files at once."""
    if task.get("fix"):
        # Correct: the right verdict, and the code agrees with the spec on
        # every hidden vector (a wrong "fix" of a no_bug task breaks some).
        ans_d = ans if isinstance(ans, dict) else {}
        verdict = str(ans_d.get("verdict", "")).strip().lower().replace("-", "_").replace(" ", "_")
        verdict_ok = verdict == task["verdict"]
        cause_ok = bool(re.search(task["cause_pattern"], str(ans_d.get("cause", "")), re.I))
        problems = ([] if verdict_ok else [f"verdict {verdict!r}, not {task['verdict']}"]) + \
                   ([] if hidden_failed == 0 else [f"{hidden_failed} hidden vectors fail"])
        return {"correct": verdict_ok and hidden_failed == 0, "verdict_ok": verdict_ok,
                "cause_ok": cause_ok, "answer": ans, "why": "; ".join(problems) or "ok"}
    if not isinstance(ans, dict):
        return {"correct": False, "answer": ans, "why": "no answer"}
    if "report" in task:
        verdict = str(ans.get("verdict", "")).strip().lower().replace("-", "_").replace(" ", "_")
        verdict_ok = verdict == task["verdict"]
        cause_ok = bool(re.search(task["cause_pattern"], str(ans.get("cause", "")), re.I))
        if task["verdict"] == "no_bug":
            problems = ([] if verdict_ok else [f"verdict {verdict!r}, not no_bug"]) + \
                       ([] if cause_ok else ["cause doesn't name the deciding condition"])
            return {"correct": verdict_ok and cause_ok, "verdict_ok": verdict_ok, "answer": ans,
                    "why": "; ".join(problems) or "ok"}
    if "question" in task:
        missing = [k for k, pat in task["grade"].items()
                   if not re.search(pat, str(ans.get(k, "")), re.I)]
        return {"correct": not missing, "answer": ans,
                "why": "ok" if not missing else f"wrong or missing: {missing}"}
    _, lines = plant(task, suite)
    want_file = "host/" + fault_file(task)
    try:
        line = int(ans.get("line"))
    except (TypeError, ValueError):
        line = None
    file_ok = str(ans.get("file", "")).endswith(want_file)
    line_ok = line is not None and any(abs(line - l) <= 1 for l in lines)
    cause_ok = bool(re.search(task["cause_pattern"], str(ans.get("cause", "")), re.I))
    problems = ([] if file_ok else [f"file is not {want_file}"]) + \
               ([] if cause_ok else ["cause doesn't name the fault"]) + \
               ([] if line_ok else [f"line {line} not near {lines}"])
    if "report" in task:
        problems = ([] if verdict_ok else [f"verdict {verdict!r}, not bug"]) + problems
        return {"correct": verdict_ok and file_ok and cause_ok, "verdict_ok": verdict_ok,
                "line_ok": line_ok, "answer": ans, "why": "; ".join(problems) or "ok"}
    return {"correct": file_ok and cause_ok, "line_ok": line_ok, "answer": ans,
            "why": "; ".join(problems) or "ok"}


# ---------------------------------------------------------------- running

def summarize_stream(lines, model):
    """Pull usage, tool calls and timing out of a stream-json transcript."""
    result, tools, steps, ctx = None, 0, [], []
    for raw in lines:
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "assistant":
            u = ev.get("message", {}).get("usage", {})
            ctx.append(u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                       + u.get("cache_read_input_tokens", 0))
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    tools += 1
                    inp = block.get("input", {})
                    brief = inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                    steps.append(f"{block['name']}: {str(brief)[:160]}")
        elif ev.get("type") == "result":
            result = ev
    if result is None:
        return None
    mu = result.get("modelUsage", {})
    main = {k: v for k, v in mu.items() if k.startswith(model)}
    other = {k: v for k, v in mu.items() if not k.startswith(model)}
    agg = lambda d, f: sum(v.get(f, 0) for v in d.values())
    return {
        "served_models": sorted(main),
        "input_tokens": agg(main, "inputTokens"),
        "cache_creation_tokens": agg(main, "cacheCreationInputTokens"),
        "cache_read_tokens": agg(main, "cacheReadInputTokens"),
        "output_tokens": agg(main, "outputTokens"),
        "thinking_tokens": agg(main, "thinkingTokens"),
        "other_models": {k: v.get("outputTokens", 0) + v.get("inputTokens", 0) for k, v in other.items()},
        "cost_usd_list": result.get("total_cost_usd"),
        "turns": result.get("num_turns"),
        # Context the task itself added: the last request's prompt size minus
        # the first one's (which is only the fixed system prompt, tools and task).
        "context_first": ctx[0] if ctx else None,
        "context_added": (ctx[-1] - ctx[0]) if ctx else None,
        "tool_calls": tools,
        "duration_ms": result.get("duration_ms"),
        "is_error": result.get("is_error"),
        "result_text": (result.get("result") or "")[:600],
        "steps": steps,
    }


def run_one(task, arm, suite, model, effort, rep, timeout):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S")
    run_id = f"{suite}.{task['id']}.{arm}.{model}.{rep}.{stamp}"
    # A neutral, random folder name: nothing in the path hints at the task or arm.
    run_dir = WORK / "w" / uuid.uuid4().hex[:12] / "task"
    build(task, arm, suite, run_dir)
    prompt = prompt_for(task, arm, suite)
    cmd = ["claude", "-p", prompt, "--model", model, "--effort", effort,
           "--output-format", "stream-json", "--verbose",
           "--permission-mode", "bypassPermissions",
           "--tools", TOOLS, "--allowedTools", TOOLS,
           "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
           "--no-session-persistence"]
    t0 = time.time()
    try:
        proc = subprocess.run(cmd, cwd=run_dir, capture_output=True, text=True, timeout=timeout)
        out, err, timed_out = proc.stdout, proc.stderr, False
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        err, timed_out = "timeout", True
    wall = time.time() - t0
    (WORK / "transcripts").mkdir(parents=True, exist_ok=True)
    (WORK / "transcripts" / f"{run_id}.jsonl").write_text(out)
    s = summarize_stream(out.splitlines(), model) or {"is_error": True, "stderr": err[-500:]}
    g = grade(task, suite, run_dir)
    shutil.rmtree(run_dir.parent, ignore_errors=True)
    steps = s.get("steps", [])
    s["why_calls"] = sum(1 for x in steps if re.search(r"(^|[\s/;&|])\./why\b|/why ", x))
    s["run_dir"] = str(run_dir)
    rec = {"run_id": run_id, "suite": suite, "task": task["id"], "kind": "fix" if task.get("fix") else "report" if "report" in task else "question" if "question" in task else "bug",
           "category": task.get("category", "question"), "model": model, "effort": effort,
           "arm": arm, "rep": rep, "timed_out": timed_out, "wall_s": round(wall, 1),
           "claude_code": claude_version(), **s, **g}
    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / f"runs-{suite}-{model}.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    return rec


_VERSION = None


def claude_version():
    global _VERSION
    if _VERSION is None:
        _VERSION = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    return _VERSION


def cmd_run(args):
    if not ENGINE.exists():
        sys.exit(f"why engine not found at {ENGINE}; build with `lake build` and copy .lake/build/bin/why there")
    all_tasks = tasks(args.suite)
    ids = list(all_tasks) if args.tasks == "all" else args.tasks.split(",")
    arms = args.arms.split(",")
    out = RESULTS / f"runs-{args.suite}-{args.model}.jsonl"
    done = set()
    if out.exists():
        for l in out.read_text().splitlines():
            if l.strip():
                r = json.loads(l)
                done.add((r["task"], r["arm"], r["rep"]))
    for rep in range(args.rep_start, args.rep_start + args.reps):
        for tid in ids:
            for arm in (arms if rep % 2 else list(reversed(arms))):
                if (tid, arm, rep) in done:
                    continue  # resume: this run is already recorded
                rec = run_one(all_tasks[tid], arm, args.suite, args.model, args.effort, rep, args.timeout)
                print(f"{args.suite:5} {rec['task']:24} {arm:8} rep{rep} correct={rec['correct']} "
                      f"out={rec.get('output_tokens')} ctx+={rec.get('context_added')} tools={rec.get('tool_calls')} why={rec.get('why_calls')} "
                      f"t={rec['wall_s']}s {rec['why']}", flush=True)
    return 0


# ---------------------------------------------------------------- summary

METRICS = [("output_tokens", "Output tokens"), ("context_added", "Context added"),
           ("tool_calls", "Tool calls"), ("wall_s", "Wall time (s)")]


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def spread(xs):
    """Interquartile range, or min-max when there are fewer than 4 runs."""
    if not xs:
        return "-"
    if len(xs) < 4:
        lo, hi = min(xs), max(xs)
    else:
        q = statistics.quantiles(xs, n=4)
        lo, hi = q[0], q[2]
    return f"{lo:,.0f}-{hi:,.0f}"


def fmt(x):
    return "-" if x != x else f"{x:,.0f}"


def strayed(r):
    """Tool calls that name an absolute path outside the run's own folder.
    (Older records don't store the folder; their own folder is the one
    random-named task folder their calls mention.)"""
    steps = r.get("steps", [])
    own = r.get("run_dir")
    if own is None:
        ids = {m for x in steps for m in re.findall(r"/w/([0-9a-f]{12})/task", x)}
        own = f"/w/{ids.pop()}/task" if len(ids) == 1 else None
    out = []
    for x in steps:
        y = re.sub(r"[^\s'\";&|]*" + re.escape(own), "", x) if own else x
        y = y.replace("/opt/why-bench/why", "")  # the why tool itself
        if re.search(r"(^|[\s'\"=])/(tmp|home|opt|root|usr|etc)\b", y):
            out.append(x)
    return out


def load_runs():
    runs = [json.loads(l) for p in sorted(RESULTS.glob("runs-*.jsonl"))
            for l in p.read_text().splitlines() if l.strip()]
    runs = [r for r in runs if "output_tokens" in r and not r.get("timed_out")]
    for r in runs:
        r["strayed"] = strayed(r)
    for r in runs:  # grade again with the current rules, from the stored answer
        r.update(grade_answer(tasks(r.get("suite", "small"))[r["task"]], r.get("suite", "small"), r.get("answer"),
                              hidden_failed=r.get("hidden_failed")))
    return runs


MODEL_ORDER = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"]


def by(runs, *keys):
    groups = {}
    for r in runs:
        groups.setdefault(tuple(r.get(k) for k in keys), []).append(r)
    return groups


def paired(runs, metric):
    """Per task, median(logic) / median(baseline). Returns the list of ratios."""
    ratios = []
    for (task,), rs in sorted(by(runs, "task").items()):
        b = [r[metric] for r in rs if r["arm"] == "baseline"]
        l = [r[metric] for r in rs if r["arm"] == "logic"]
        if b and l and med(b) > 0:
            ratios.append(med(l) / med(b))
    return ratios


def cmd_summarize(_args):
    runs = load_runs()
    models = [m for m in MODEL_ORDER if any(r["model"] == m for r in runs)]
    models += sorted({r["model"] for r in runs} - set(models))
    out = ["# Results", "",
           "Generated by `python bench.py summarize` from `results/runs-*.jsonl`. "
           "Medians over runs, with the interquartile range (min-max under 4 runs) in brackets. "
           "See [README.md](../README.md) for the method.", ""]
    versions = sorted({r.get("claude_code", "?") for r in runs})
    served = sorted({m for r in runs for m in r.get("served_models", [])})
    out += [f"- Claude Code: {', '.join(versions)}", f"- Models served: {', '.join(served)}",
            f"- Effort: {', '.join(sorted({r['effort'] for r in runs}))}",
            f"- Runs: {len(runs)} (timed-out runs excluded: "
            f"{sum(1 for p in RESULTS.glob('runs-*.jsonl') for l in p.read_text().splitlines() if l.strip() and json.loads(l).get('timed_out'))})", ""]

    out += ["## All tasks, by arm", "",
            "| Suite | Model | Arm | Runs | Correct | Line right | " + " | ".join(n for _, n in METRICS) + " | Used ./why | List-price cost / run |",
            "| --- | --- | --- | ---: | ---: | ---: | " + " | ".join("---:" for _ in METRICS) + " | ---: | ---: |"]
    for suite in SUITES:
        for m in models:
            for arm in ("baseline", "logic"):
                rs = [r for r in runs if r.get("suite", "small") == suite and r["model"] == m and r["arm"] == arm]
                if not rs:
                    continue
                cells = [f"{fmt(med([r[k] for r in rs]))} ({spread([r[k] for r in rs])})" for k, _ in METRICS]
                used = "-" if arm == "baseline" else f"{sum(1 for r in rs if r.get('why_calls'))}/{len(rs)}"
                bugs = [r for r in rs if r["kind"] == "bug"]
                cost = med([r["cost_usd_list"] for r in rs if r.get("cost_usd_list") is not None])
                out.append(f"| {suite} | {m} | {arm} | {len(rs)} | {sum(r['correct'] for r in rs)}/{len(rs)} | "
                           f"{sum(bool(r.get('line_ok')) for r in bugs)}/{len(bugs)} | "
                           + " | ".join(cells) + f" | {used} | ${cost:.2f} |")
    out += ["", "## Paired by task: logic arm relative to baseline", "",
            "For each task, the logic arm's median divided by the baseline's median; "
            "the table gives the median of those ratios across tasks, and how many tasks went down. "
            "Below 1.00 means the logic arm used less.", "",
            "| Suite | Model | Tasks | " + " | ".join(n for _, n in METRICS) + " |",
            "| --- | --- | ---: | " + " | ".join("---:" for _ in METRICS) + " |"]
    for suite in SUITES:
        for m in models:
            rs = [r for r in runs if r.get("suite", "small") == suite and r["model"] == m]
            if not rs:
                continue
            cells, n = [], 0
            for k, _ in METRICS:
                ratios = paired(rs, k)
                n = max(n, len(ratios))
                cells.append(f"{med(ratios):.2f} ({sum(x < 1 for x in ratios)}/{len(ratios)} down)" if ratios else "-")
            out.append(f"| {suite} | {m} | {n} | " + " | ".join(cells) + " |")
    out += ["", "## By task (median output tokens, baseline → logic)", "",
            "| Task | Category | Suite | Model | Baseline | Logic | Correct (baseline / logic) |",
            "| --- | --- | --- | --- | ---: | ---: | --- |"]
    for (task, suite, m), rs in sorted(by(runs, "task", "suite", "model").items(),
                                       key=lambda kv: (kv[0][1] or "small", kv[0][0], MODEL_ORDER.index(kv[0][2]) if kv[0][2] in MODEL_ORDER else 9)):
        b = [r for r in rs if r["arm"] == "baseline"]
        l = [r for r in rs if r["arm"] == "logic"]
        out.append(f"| {task} | {rs[0]['category']} | {suite or 'small'} | {m} | "
                   f"{fmt(med([r['output_tokens'] for r in b]))} | {fmt(med([r['output_tokens'] for r in l]))} | "
                   f"{sum(r['correct'] for r in b)}/{len(b)} / {sum(r['correct'] for r in l)}/{len(l)} |")
    stray = [r["run_id"] for r in runs if r.get("strayed")]
    out += ["", f"Runs that touched paths outside their task folder: {len(stray)}"
            + (" (" + ", ".join(stray) + ")" if stray else ""), ""]
    (RESULTS / "RESULTS.md").write_text("\n".join(out))
    print("\n".join(out))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    r = sub.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--suite", choices=list(SUITES), default="large")
    r.add_argument("--effort", default="high")
    r.add_argument("--tasks", default="all")
    r.add_argument("--arms", default="baseline,logic")
    r.add_argument("--reps", type=int, default=1)
    r.add_argument("--rep-start", type=int, default=1)
    r.add_argument("--timeout", type=int, default=1200)
    sub.add_parser("summarize")
    a = ap.parse_args()
    return {"check": cmd_check, "run": cmd_run, "summarize": cmd_summarize}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
