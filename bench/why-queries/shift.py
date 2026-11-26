"""Long, multi-turn scenarios: one session handles a series of tickets.

One Claude Code session gets the tickets one at a time and is resumed
between them, so everything it reads stays in its context for the rest of
the session. Two scenarios:

- `bugs` (shift.json): an on-call shift. The code holds every fix-suite
  fault at once (both models); the case-based tickets are reports where the
  user is wrong.
- `features` (shift_features.json): product changes. Before each ticket the
  model's specification is replaced by its next version (features.json,
  generated from Bench/src by gen_specs.py), and the session must implement
  the change.

usage:
  python shift.py check [--shift bugs|features]
  python shift.py run --model claude-sonnet-5-5 --reps 3 [--shift features]
  python shift.py summarize          (writes results/SHIFT.md)

After each ticket the session's code is replayed against hidden vectors.
A bug ticket counts as fixed when the hidden vectors that only its fault
breaks pass at the end of its turn; a no_bug ticket counts as left alone when
its turn adds no hidden failures. A ticket is correct when its verdict is
right and it is fixed (or left alone). A feature ticket is correct when, at
the end of its turn, the code agrees with the new specification on every
feature vector and on every older hidden vector.
"""
import argparse
import datetime as dt
import json
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid

import bench
import gen_inputs
import gen_specs
from bench import HERE, RESULTS, WORK, ENGINE, TOOLS, SPEC, DESCRIBE, plant, host_tree, host_decide

MODELS = ["access", "deploy"]
SHIFTS = {"bugs": "shift.json", "features": "shift_features.json"}
MODE = "bugs"


def tickets():
    order = json.loads((HERE / SHIFTS[MODE]).read_text())["order"]
    pool = {**bench.tasks("fix"), **bench.tasks("hard"),
            **{f["id"]: {**f, "verdict": "feature"} for f in json.loads((HERE / "features.json").read_text())}}
    return [{**pool[tid], "ticket": f"T{k + 1:02d}"} for k, tid in enumerate(order)]


def bug_tickets():
    return [t for t in tickets() if t["verdict"] == "bug"]


def model_name(m, version):
    return m if version == 1 else f"{m}{version}"


def spec_text(m, version):
    """The specification a session sees for a model version, under the
    model's plain name."""
    base = SPEC[m]
    text = (HERE / "Bench" / "src" / f"{base}.lean.in").read_text()
    return gen_specs.render(text, gen_specs.VERSIONS[base][version - 1], base, m)


_FEAT = {}


def feature_vectors(m, version):
    """Vectors for the feature inputs under a spec version (built with the
    local engine and cached in vectors/, which git ignores)."""
    key = (m, version)
    if key not in _FEAT:
        path = HERE / "vectors" / f"feature-{model_name(m, version)}.json"
        if not path.exists():
            local = HERE / ".lake" / "build" / "bin" / "why"
            out = subprocess.run([str(local), "expect", model_name(m, version),
                                  str(HERE / "inputs" / f"feature-{m}.json")],
                                 capture_output=True, text=True, check=True).stdout
            path.write_text(out)
        _FEAT[key] = json.loads(path.read_text())
    return _FEAT[key]


def feature_fails(tr, m, version):
    vec = feature_vectors(m, version)
    got = host_decide(sub(tr, m), m, [c["input"] for c in vec])
    return {c["id"] for g, c in zip(got, vec) if g != c["expected"]}


CHECK_N = 1000


def check_inputs(m):
    """Inputs for `./why check`: the same generators as the hidden tests, from
    a different seed, so the hidden cases themselves are never shown."""
    gen, _ = (gen_inputs.FEATURE if MODE == "features" else gen_inputs.WIDE)[m]
    r = random.Random(f"tribrach-why-bench-check-{MODE}-{m}")
    return [{"id": f"chk-{k + 1:04d}", "input": gen(r)} for k in range(CHECK_N)]


def tree(skip=None):
    """Both packages with every bug ticket's fault planted, except `skip`."""
    out = {}
    for m in MODELS:
        out.update({f"{p}": s for p, s in host_tree(m, "fix").items()})
    for t in bug_tickets():
        if t["id"] == skip:
            continue
        for e in t["edits"]:
            assert out[e["file"]].count(e["find"]) == 1, f"{t['id']}: find text must occur once"
            out[e["file"]] = out[e["file"]].replace(e["find"], e["replace"])
    return out


def sub(tr, m):
    return {k: v for k, v in tr.items() if k.startswith(m + "/")}


def hidden_fails(tr):
    """{model: set of failing hidden ids} for a host tree."""
    out = {}
    for m in MODELS:
        hid = bench.hidden_vectors(m)
        got = host_decide(sub(tr, m), m, [c["input"] for c in hid])
        out[m] = {c["id"] for g, c in zip(got, hid) if g != c["expected"]}
    return out


_OWN = None


def own_ids():
    """For each bug ticket, the hidden ids that fail with only its fault and
    pass when every other fault is planted: fixing it must make them pass."""
    global _OWN
    if _OWN is None:
        _OWN = {}
        for t in bug_tickets():
            m = t["model"]
            clean = {k: v for mm in MODELS for k, v in host_tree(mm, "fix").items()}
            alone = hidden_fails({**clean, **plant(t, "fix")[0]})[m]
            others = hidden_fails(tree(skip=t["id"]))[m]
            _OWN[t["id"]] = sorted(alone - others)
    return _OWN


_QUIET = {}


def quiet(m):
    """Visible vectors that pass with all faults planted and with each one."""
    if MODE == "features":
        return bench.vectors(m)
    if m not in _QUIET:
        cases = bench.quiet_vectors(m, "fix")
        got = host_decide(sub(tree(), m), m, [c["input"] for c in cases])
        _QUIET[m] = [c for g, c in zip(got, cases) if g == c["expected"]]
    return _QUIET[m]


def check_features():
    """The reference solutions in features.json, applied in order, agree with
    each new version on every feature vector and every older hidden vector,
    and each ticket's new version changes some feature vectors."""
    ok, tr, version = True, tree(), {m: 1 for m in MODELS}
    for t in tickets():
        m = t["model"]
        before = feature_vectors(m, version[m])
        version[m] = t["version"]
        after = feature_vectors(m, version[m])
        changed = sum(a["expected"] != b["expected"] for a, b in zip(before, after))
        unsolved = len(feature_fails(tr, m, version[m]))
        for e in t["solution"]:
            assert tr[e["file"]].count(e["find"]) == 1, f"{t['id']}: solution find text must occur once"
            tr[e["file"]] = tr[e["file"]].replace(e["find"], e["replace"])
        bad = len(feature_fails(tr, m, version[m])) + len(hidden_fails(tr)[m])
        good = changed > 0 and bad == 0 and unsolved > 0
        print(f"{t['ticket']} {t['id']}: version {version[m]} changes {changed} feature vectors; "
              f"before the change {unsolved} fail; with the reference solution {bad} fail"
              + ("" if good else "  <-- PROBLEM"))
        ok &= good
    return 0 if ok else 1


def cmd_check(_a):
    if MODE == "features":
        return check_features()
    ok = True
    full = hidden_fails(tree())
    print(f"all faults planted: hidden failing {[len(full[m]) for m in MODELS]}; "
          f"visible vectors {[len(quiet(m)) for m in MODELS]}")
    for t in tickets():
        line = f"{t['ticket']} {t['id']} ({t['verdict']})"
        if t["verdict"] == "bug":
            n = len(own_ids()[t["id"]])
            line += f": {n} hidden vectors only this fault breaks"
            ok &= n > 0
        elif "case" in t:
            m = t["model"]
            want = bench.spec_expect(m, [t["case"]["input"]])[0]
            got = host_decide(sub(tree(), m), m, [t["case"]["input"]])[0]
            line += f": spec {want}, shift code {got}"
            ok &= want == got
        print(line + ("" if ok else "  <-- PROBLEM"))
    return 0 if ok else 1


# ---------------------------------------------------------------- prompts

INTRO = """You are on call this shift for two services, both in this directory:

- host/access/: a {access}. host/deploy/: a {deploy}. Each is a Python package whose `decide` function is the entry point the tests call.
- spec/Access.lean and spec/Deploy.lean are their specifications (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide). The specifications are the source of truth.
- tests/access.json and tests/deploy.json hold test vectors; their expected decisions come from the specifications. `python3 run_tests.py` replays them (they all pass) and prints what the code decides for cases without expected decisions. `python3 run_tests.py <access|deploy> <file.json>` replays a file of your own in the same format.
{tool}
Tickets arrive one at a time. For each ticket, find out whether the code disagrees with the specification (a bug) or the user's expectation is wrong. If it is a bug, fix it under host/ so that the code agrees with the specification for every input, not only the reported situation: hidden tests will check at the end of the shift. If the user is wrong, leave the code alone. Do not change spec/, tests/ or run_tests.py; you may create other files.

When you are done with a ticket, write answers/<ticket>.json:

{{"verdict": "bug" or "no_bug", "files": [<paths under host/ that you changed>], "cause": "<one sentence: what was wrong, or the condition that decides the reported situation>"}}

Then stop and wait for the next ticket. Work only inside this directory.

{first}"""

WHY_TOOL = """
You also have `./why`, which answers questions from the specifications for any case:

- `./why <access|deploy> <case-id>`: the expected decisions for that case, each with its why tree (the rules and facts that produce it).
- `./why <access|deploy> <case-id> whynot <decision...>`: why a decision does not follow, for example `./why access acc-01 whynot open d-office-2`.
- `./why <access|deploy> <case-id> why <predicate> [args...]`: why any fact holds (or, if it doesn't, why not).
- `./why <access|deploy> <case-id> facts`: the facts the specification's `encode` step produces from that case's input.
- `./why <access|deploy> --cases <file.json> <case-id> ...`: the same, for a case in a file of your own (same format as tests/, "expected" not needed).

Asking `./why` about the reported situation is usually the quickest way to see which conditions decide it.
"""

CHECK_TOOL = """- `./why check <access|deploy>`: runs the code against the specification on 1,000 generated inputs and reports how many disagree, with the first disagreement's input, both answers and the specification's reasons (`--show N` for more). Use it to confirm a change agrees everywhere, not only on the reported situation.
"""


FEATURE_INTRO = """You maintain two services, both in this directory:

- host/access/: a {access}. host/deploy/: a {deploy}. Each is a Python package whose `decide` function is the entry point the tests call.
- spec/Access.lean and spec/Deploy.lean are their specifications (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide). The specifications are the source of truth.
- tests/access.json and tests/deploy.json hold test vectors; their expected decisions come from the specifications. `python3 run_tests.py` replays them (they all pass now) and prints what the code decides for cases without expected decisions. `python3 run_tests.py <access|deploy> <file.json>` replays a file of your own in the same format.
{tool}
Tickets arrive one at a time. Each is a product change: the specification has already been updated, and you implement the change under host/ so that the code agrees with the new specification for every input, including inputs that use the new fields together with the existing rules. Hidden tests will check after each ticket. Do not change spec/, tests/ or run_tests.py; you may create other files.

When you are done with a ticket, write answers/<ticket>.json:

{{"files": [<paths under host/ that you changed>], "summary": "<one sentence>"}}

Then stop and wait for the next ticket. Work only inside this directory.

{first}"""


PROSE = {"access": "ACCESS.md", "deploy": "DEPLOY.md"}


def prose_intro(intro):
    """The intro for the prose arm: Markdown specifications instead of Lean."""
    return intro.replace(
        "- spec/Access.lean and spec/Deploy.lean are their specifications (Lean 4: an `encode` step turns the JSON input into facts, then Datalog-style rules decide). The specifications are the source of truth.",
        "- spec/ACCESS.md and spec/DEPLOY.md are their specifications. The specifications are the source of truth.")


def ticket_text(t, arm="baseline"):
    report = t["report"]
    if arm == "prose":
        report = report.replace("spec/Deploy.lean", "spec/DEPLOY.md").replace("spec/Access.lean", "spec/ACCESS.md")
    text = f"Ticket {t['ticket']} ({t['model']}): {report}"
    if "case" in t:
        text += f"\n\nCase {t['case']['id']} in tests/{t['model']}.json is the exact situation."
    return text


def write_why(run_dir, version):
    """The logic arm's ./why, pointed at each model's current spec version
    (with `./why check <model>` when the session has check/)."""
    w = run_dir / "why"
    cases_for = " ".join(f'{m}) n={model_name(m, version[m])} ;;' for m in MODELS)
    w.write_text('#!/bin/sh\nd="$(dirname "$0")"; m="$1"; shift\n'
                 'chk=; if [ "$m" = check ] && [ -d "$d/check" ]; then chk=1; m="$1"; shift; fi\n'
                 f'case "$m" in {cases_for} *) n="$m" ;; esac\n'
                 f'if [ -n "$chk" ]; then exec python3 "$d/why_check.py" "{ENGINE}" "$n" "$m" "$@"; fi\n'
                 'cases="$d/tests/$m.json"\n'
                 'if [ "$1" = "--cases" ]; then cases="$2"; shift 2; fi\n'
                 f'exec "{ENGINE}" "$n" "$cases" "$@"\n')
    w.chmod(0o755)


def build(arm, run_dir):
    if run_dir.exists():
        shutil.rmtree(run_dir)
    for d in ("host", "spec", "tests", "answers"):
        (run_dir / d).mkdir(parents=True)
    for rel, src in tree().items():
        (run_dir / "host" / rel).parent.mkdir(parents=True, exist_ok=True)
        (run_dir / "host" / rel).write_text(src)
    for m in MODELS:
        if arm == "prose":
            shutil.copy(HERE / "spec_prose" / PROSE[m], run_dir / "spec")
        else:
            (run_dir / "spec" / f"{SPEC[m]}.lean").write_text(spec_text(m, 1))
        cases = quiet(m) + [t["case"] for t in tickets() if "case" in t and t["model"] == m]
        (run_dir / "tests" / f"{m}.json").write_text(json.dumps(cases, indent=1) + "\n")
    shutil.copy(HERE / "run_tests.py", run_dir)
    if arm == "check":
        (run_dir / "check").mkdir()
        for m in MODELS:
            (run_dir / "check" / f"{m}.json").write_text(json.dumps(check_inputs(m), indent=1) + "\n")
        shutil.copy(HERE / "why_check.py", run_dir)
    if arm in ("logic", "check"):
        write_why(run_dir, {m: 1 for m in MODELS})


# ---------------------------------------------------------------- running

def turn_stats(lines, model):
    """Per-request context sizes and the turn's result event."""
    ctx, tools, steps, result, compacted, session = [], 0, [], None, 0, None
    for raw in lines:
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        session = ev.get("session_id") or session
        if ev.get("type") == "system" and ev.get("subtype") == "compact_boundary":
            compacted += 1
        if ev.get("type") == "assistant":
            u = ev.get("message", {}).get("usage", {})
            ctx.append(u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                       + u.get("cache_read_input_tokens", 0))
            for b in ev.get("message", {}).get("content", []):
                if b.get("type") == "tool_use":
                    tools += 1
                    inp = b.get("input", {})
                    steps.append(f"{b['name']}: {str(inp.get('command') or inp.get('file_path') or inp.get('pattern') or '')[:160]}")
        elif ev.get("type") == "result":
            result = ev
    mu = (result or {}).get("modelUsage", {})
    out_tokens = sum(v.get("outputTokens", 0) for k, v in mu.items() if k.startswith(model))
    return {"session_id": session, "requests": len(ctx), "context_start": ctx[0] if ctx else None,
            "context_end": ctx[-1] if ctx else None, "context_sum": sum(ctx),
            "output_tokens": out_tokens, "tool_calls": tools, "steps": steps,
            "why_calls": sum(1 for x in steps if re.search(r"(^|[\s/;&|])\./why\b|/why ", x)),
            "compactions": compacted, "cost_usd_list": (result or {}).get("total_cost_usd"),
            "duration_ms": (result or {}).get("duration_ms"), "is_error": (result or {}).get("is_error", True)}


def snapshot(run_dir):
    root = run_dir / "host"
    return {str(p.relative_to(root)): p.read_text(errors="replace")
            for p in sorted(root.rglob("*.py")) if "__pycache__" not in p.parts}


def grade_feature(t, tr, version, prev_fails):
    """Strict: every vector passes. `carried` counts failing vectors that
    already failed after the model's previous ticket (left over from an
    earlier mistake), so `own_ok` judges this ticket's change alone."""
    m = t["model"]
    feat = feature_fails(tr, m, version[m])
    old = hidden_fails(tr)[m]
    carried = feat & prev_fails.get(m, set())
    prev_fails[m] = feat
    ok = not feat and not old
    why = [] if ok else [f"{len(feat)} feature ({len(carried)} carried over) and {len(old)} older hidden vectors fail"]
    return {"code_ok": ok, "correct": ok, "feature_failed": len(feat), "carried_over": len(carried),
            "own_ok": not (feat - carried) and not old, "hidden_failed": len(old),
            "why": "; ".join(why) or "ok"}


def grade_ticket(t, before, after, ans):
    ans = ans if isinstance(ans, dict) else {}
    verdict = str(ans.get("verdict", "")).strip().lower().replace("-", "_").replace(" ", "_")
    verdict_ok = verdict == t["verdict"]
    m = t["model"]
    if t["verdict"] == "bug":
        left = sorted(set(own_ids()[t["id"]]) & after[m])
        done = not left
        why = [] if done else [f"{len(left)} of its hidden vectors still fail"]
    else:
        new = sorted(after[m] - before[m])
        done = not new
        why = [] if done else [f"the turn broke {len(new)} hidden vectors"]
    if not verdict_ok:
        why.insert(0, f"verdict {verdict!r}, not {t['verdict']}")
    return {"verdict_ok": verdict_ok, "code_ok": done, "correct": verdict_ok and done,
            "cause_ok": bool(re.search(t["cause_pattern"], str(ans.get("cause", "")), re.I)),
            "why": "; ".join(why) or "ok"}


def run_shift(arm, model, effort, rep, timeout):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S")
    run_dir = WORK / "w" / uuid.uuid4().hex[:12] / "task"
    build(arm, run_dir)
    tool = {"logic": WHY_TOOL, "check": WHY_TOOL.replace("\nAsking", CHECK_TOOL + "\nAsking")}.get(arm, "")
    version = {m: 1 for m in MODELS}
    intro = FEATURE_INTRO if MODE == "features" else INTRO
    if arm == "prose":
        intro = prose_intro(intro)
        assert "spec/ACCESS.md" in intro
    base = ["--model", model, "--effort", effort, "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions", "--tools", TOOLS, "--allowedTools", TOOLS,
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    session, turns, transcript = None, [], []
    prev_out, prev_cost = 0, 0.0  # a resumed session reports usage and cost cumulatively
    before = hidden_fails(snapshot(run_dir)) if MODE == "bugs" else None
    prev_fails = {}
    t0 = time.time()
    for k, t in enumerate(tickets()):
        if t["verdict"] == "feature":  # the spec moves to the ticket's version first
            version[t["model"]] = t["version"]
            if arm == "prose":  # the Markdown spec gets the change appended, in the ticket's words
                change = t["report"].split(" spec/")[0].replace("Product change: ", "", 1)
                with open(run_dir / "spec" / PROSE[t["model"]], "a") as fh:
                    fh.write(f"\n## Change: {t['id']}\n\n{change[0].upper() + change[1:]}\n")
            else:
                (run_dir / "spec" / f"{SPEC[t['model']]}.lean").write_text(spec_text(t["model"], t["version"]))
            if arm in ("logic", "check"):
                write_why(run_dir, version)
        prompt = (intro.format(access=DESCRIBE["access"], deploy=DESCRIBE["deploy"], tool=tool,
                               first=ticket_text(t, arm)) if k == 0 else ticket_text(t, arm))
        cmd = ["claude", "-p", prompt] + base + (["--resume", session] if session else [])
        ts = time.time()
        try:
            proc = subprocess.run(cmd, cwd=run_dir, capture_output=True, text=True, timeout=timeout)
            out, timed_out = proc.stdout, False
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
            timed_out = True
        transcript.append(out)
        st = turn_stats(out.splitlines(), model)
        session = st.pop("session_id") or session
        cum_out, cum_cost = st["output_tokens"], st["cost_usd_list"]
        if cum_out >= prev_out:
            st["output_tokens"] = cum_out - prev_out
            prev_out = cum_out
        if cum_cost is not None and cum_cost >= prev_cost:
            st["cost_usd_list"] = round(cum_cost - prev_cost, 6)
            prev_cost = cum_cost
        p = run_dir / "answers" / f"{t['ticket']}.json"
        try:
            ans = json.loads(p.read_text()) if p.exists() else None
        except json.JSONDecodeError:
            ans = None
        if MODE == "features":
            after = None
            g = grade_feature(t, snapshot(run_dir), version, prev_fails)
            extra = {}
        else:
            after = hidden_fails(snapshot(run_dir))
            g = grade_ticket(t, before, after, ans)
            extra = {"hidden_failing_after": {m: len(after[m]) for m in MODELS}}
        turns.append({"ticket": t["ticket"], "task": t["id"], "verdict": t["verdict"], "timed_out": timed_out,
                      "wall_s": round(time.time() - ts, 1), "answer": ans, **extra, **st, **g})
        print(f"  {arm:8} rep{rep} {t['ticket']} {t['id']:26} correct={g['correct']} out={st['output_tokens']} "
              f"ctx={st['context_start']}->{st['context_end']} tools={st['tool_calls']} why={st['why_calls']} "
              f"t={turns[-1]['wall_s']}s {g['why']}", flush=True)
        if after is not None:
            before = after
        if timed_out or session is None:
            break
    final = hidden_fails(snapshot(run_dir))
    if MODE == "features":
        final_tree = snapshot(run_dir)
        for m in MODELS:
            final[m] = final[m] | feature_fails(final_tree, m, version[m])
    (WORK / "transcripts").mkdir(parents=True, exist_ok=True)
    run_id = f"{MODE}.{arm}.{model}.{rep}.{stamp}"
    (WORK / "transcripts" / f"{run_id}.jsonl").write_text("".join(transcript))
    shutil.rmtree(run_dir.parent, ignore_errors=True)
    rec = {"run_id": run_id, "suite": "shift" if MODE == "bugs" else "features", "model": model, "effort": effort, "arm": arm, "rep": rep,
           "claude_code": bench.claude_version(), "run_dir": str(run_dir), "wall_s": round(time.time() - t0, 1),
           "tickets": len(turns), "correct": sum(x["correct"] for x in turns),
           "final_hidden_failing": sum(len(v) for v in final.values()),
           "output_tokens": sum(x["output_tokens"] for x in turns),
           "context_end": turns[-1]["context_end"] if turns else None,
           "context_sum": sum(x["context_sum"] for x in turns),
           "tool_calls": sum(x["tool_calls"] for x in turns),
           "why_calls": sum(x["why_calls"] for x in turns),
           "compactions": sum(x["compactions"] for x in turns),
           "cost_usd_list": round(sum(x["cost_usd_list"] or 0 for x in turns), 4),
           "turns": turns}
    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / f"runs-{rec['suite']}-{model}.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    return rec


def cmd_run(a):
    if not ENGINE.exists():
        sys.exit(f"why engine not found at {ENGINE}")
    out = RESULTS / f"runs-{'shift' if MODE == 'bugs' else 'features'}-{a.model}.jsonl"
    done = set()
    if out.exists():
        done = {(r["arm"], r["rep"]) for r in map(json.loads, out.read_text().splitlines()) if r}
    arms = a.arms.split(",")
    for rep in range(a.rep_start, a.rep_start + a.reps):
        for arm in (arms if rep % 2 else list(reversed(arms))):
            if (arm, rep) in done:
                continue
            r = run_shift(arm, a.model, a.effort, rep, a.timeout)
            print(f"shift {arm:8} rep{rep} correct={r['correct']}/{r['tickets']} final_hidden_failing="
                  f"{r['final_hidden_failing']} out={r['output_tokens']} context_end={r['context_end']} "
                  f"context_sum={r['context_sum']} why={r['why_calls']} compactions={r['compactions']} "
                  f"cost=${r['cost_usd_list']} t={r['wall_s']}s", flush=True)
    return 0


# ---------------------------------------------------------------- summary

def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


ARMS = ("prose", "baseline", "logic", "check")
ARM_NAMES = {"prose": "Markdown spec", "baseline": "Lean spec", "logic": "Lean spec + ./why",
             "check": "Lean spec + ./why + check"}


def summarize_mode(mode):
    global MODE
    MODE = mode
    suite = "shift" if mode == "bugs" else "features"
    runs = [json.loads(l) for p in sorted(RESULTS.glob(f"runs-{suite}-*.jsonl"))
            for l in p.read_text().splitlines() if l.strip()]
    if not runs:
        return []
    order = [m for m in bench.MODEL_ORDER if any(r["model"] == m for r in runs)]
    arms = [a for a in ARMS if any(r["arm"] == a for r in runs)]
    n = len(tickets())
    title = "Bug shift" if mode == "bugs" else "Feature shift"
    out = [f"## {title} ({SHIFTS[mode]}, {n} tickets)", "",
           "| Model | Arm | Runs | Correct tickets | All hidden pass | Output tokens | Context at end | Tokens read | Tool calls | ./why calls | Compactions | Wall time (s) | List-price cost |",
           "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for m in order:
        for arm in arms:
            rs = [r for r in runs if r["model"] == m and r["arm"] == arm]
            if not rs:
                continue
            f = lambda k: med([r[k] for r in rs])
            out.append(f"| {m} | {ARM_NAMES[arm]} | {len(rs)} | {f('correct')}/{n} | "
                       f"{sum(r['final_hidden_failing'] == 0 for r in rs)}/{len(rs)} | {f('output_tokens'):,.0f} | "
                       f"{f('context_end'):,.0f} | {f('context_sum'):,.0f} | {f('tool_calls'):.0f} | {f('why_calls'):.0f} | "
                       f"{f('compactions'):.0f} | {f('wall_s'):.0f} | ${f('cost_usd_list'):.2f} |")
    out += ["", "Context at the start of each ticket (median):", "",
            "| Model | Arm | " + " | ".join(f"T{k + 1:02d}" for k in range(n)) + " | End |",
            "| --- | --- | " + " | ".join("---:" for _ in range(n)) + " | ---: |"]
    for m in order:
        for arm in arms:
            rs = [r for r in runs if r["model"] == m and r["arm"] == arm]
            if not rs:
                continue
            cells = []
            for k in range(n):
                v = med([r["turns"][k]["context_start"] for r in rs if len(r["turns"]) > k])
                cells.append(f"{v / 1000:.0f}k" if v else "-")
            cells.append(f"{med([r['context_end'] for r in rs]) / 1000:.0f}k")
            out.append(f"| {m} | {ARM_NAMES[arm]} | " + " | ".join(cells) + " |")
    out += ["", "Correct runs per ticket (" + " / ".join(ARM_NAMES[a] for a in arms) + "):", "",
            "| Ticket | Task | Kind | " + " | ".join(order) + " |",
            "| --- | --- | --- | " + " | ".join("---" for _ in order) + " |"]
    for k, t in enumerate(tickets()):
        cells = []
        for m in order:
            c = []
            for arm in arms:
                rs = [r for r in runs if r["model"] == m and r["arm"] == arm and len(r["turns"]) > k]
                c.append(f"{sum(r['turns'][k]['correct'] for r in rs)}/{len(rs)}")
            cells.append(" / ".join(c))
        out.append(f"| {t['ticket']} | {t['id']} | {t['verdict']} | " + " | ".join(cells) + " |")
    return out + [""]


def cmd_summarize(_a):
    out = ["# Long-session results", "",
           "Generated by `python shift.py summarize` from `results/runs-shift-*.jsonl` (bug shift) and "
           "`results/runs-features-*.jsonl` (feature shift). One resumed session handles every ticket in turn. "
           "Medians over runs.", "",
           "- **Correct tickets**: tickets whose verdict (bug shift) and code were right at the end of the ticket's turn.",
           "- **All hidden pass**: runs whose final code agrees with the specification on every hidden vector.",
           "- **Context at end**: the size of the last request's prompt.",
           "- **Tokens read**: the sum of every request's prompt size over the session (what a long session pays for, cached or not).",
           ""]
    out += summarize_mode("bugs") + summarize_mode("features")
    (RESULTS / "SHIFT.md").write_text("\n".join(out) + "\n")
    print("\n".join(out))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shift", choices=list(SHIFTS), default="bugs")
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("check")
    r = sp.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--effort", default="high")
    r.add_argument("--arms", default="baseline,logic")
    r.add_argument("--reps", type=int, default=1)
    r.add_argument("--rep-start", type=int, default=1)
    r.add_argument("--timeout", type=int, default=1200, help="per ticket, in seconds")
    sp.add_parser("summarize")
    a = ap.parse_args()
    global MODE
    MODE = a.shift
    return {"check": cmd_check, "run": cmd_run, "summarize": cmd_summarize}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
