"""Demo plumbing between feedback services and Tribrach triage.

    python3 feedback.py pull --offline     # fixtures/ -> out/reports.json
    lake exe triage --json out/reports.json > out/triage.jsonl
    python3 feedback.py route              # out/triage.jsonl -> out/outbox/
    python3 feedback.py digest             # -> out/digests/ (issue comments)

In GitHub Actions, `pull --event "$GITHUB_EVENT_PATH"` reads the one issue
that triggered the run straight from the event file, so no token is needed
to read it (see workflows/triage-issues.yml).

`pull` turns each service's payload into a `tribrach.report.v1` envelope.
Only the report the app attached is kept, plus where it came from; anything
else in the payload (names, emails, free-form fields) is dropped. `route`
sends each verdict where `tribrach-triage.toml` says, here by writing the
issue, card or reply it would create into `out/outbox/`.

Live connectors are not part of this example. Without `--offline`, `pull`
only checks that the configured token variables are set, then stops.
"""

import json
import os
import pathlib
import re
import sys
import tomllib

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
MARKER = "<!-- tribrach-triage -->"
REPORT_KEYS = ("model", "stamp", "privacy", "start", "ops", "observed", "expected")


def config():
    return tomllib.loads((HERE / "tribrach-triage.toml").read_text())


def envelope(cfg, service, ref, url, payload, app, note):
    """A tribrach.report.v1 envelope from the report an app attached."""
    env = {
        "format": "tribrach.report.v1",
        "id": f"{service}-{ref}",
        "model": payload.get("model", cfg["model"]),
        "source": {"service": service, "ref": str(ref)},
    }
    if url:
        env["source"]["url"] = url
    if app:
        env["app"] = app
    for key in REPORT_KEYS[1:]:
        if key in payload:
            env[key] = payload[key]
    if note:
        env["note"] = note
    return env


def section(body, heading):
    m = re.search(rf"### {re.escape(heading)}\n\n(.*?)(?:\n### |\Z)", body, re.S)
    return m.group(1).strip() if m else ""


def from_github_issue_form(cfg, issue):
    m = re.search(r"```tribrach-report\n(.*?)\n```", issue["body"], re.S)
    if not m:
        return None, f"issue {issue['number']}: no report attached"
    version, _, platform = section(issue["body"], "App version").partition(" ")
    app = {"version": version, "platform": platform.strip("()")} if version else None
    return envelope(cfg, "github-issue-form", issue["number"], issue["html_url"],
                    json.loads(m.group(1)), app,
                    section(issue["body"], "What happened?")), None


def from_crash_reporter(cfg, event):
    files = [a for a in event.get("attachments", []) if a["filename"] == "tribrach-report.json"]
    if not files:
        return None, f"event {event['event_id']}: no report attached"
    app = {"version": event["release"].rpartition("@")[2], "platform": event["platform"]}
    note = event.get("user_feedback", {}).get("comments", "")
    return envelope(cfg, "crash-reporter", event["event_id"], None,
                    json.loads(files[0]["data"]), app, note), None


def from_helpdesk(cfg, ticket):
    files = [a for a in ticket.get("attachments", []) if a["file_name"] == "tribrach-report.json"]
    if not files:
        return None, f"ticket {ticket['id']}: no report attached"
    fields = ticket.get("custom_fields", {})
    app = {"version": fields.get("app_version", ""), "platform": fields.get("platform", "")}
    # The requester's name and email stay in the helpdesk.
    return envelope(cfg, "helpdesk", ticket["id"], ticket["url"],
                    json.loads(files[0]["content"]), app, ticket["subject"]), None


ADAPTERS = {
    "github-issue-form": from_github_issue_form,
    "crash-reporter-feedback": from_crash_reporter,
    "helpdesk-ticket": from_helpdesk,
}


def pull(offline, event=None, out=OUT):
    cfg = config()
    reports, skipped = [], []
    if event:
        # One issue, from a GitHub Actions `issues` event file.
        env, why = from_github_issue_form(cfg, json.loads(pathlib.Path(event).read_text())["issue"])
        (reports if env else skipped).append(env or f"event: {why}")
    else:
        if not offline:
            missing = [s["token_env"] for s in cfg["source"] if not os.environ.get(s["token_env"])]
            if missing:
                sys.exit(f"set {', '.join(sorted(set(missing)))} (see .env.example), or use --offline")
            sys.exit("live connectors are not part of this example; use --offline")
        for src in cfg["source"]:
            for item in json.loads((HERE / src["fixture"]).read_text()):
                env, why = ADAPTERS[src["kind"]](cfg, item)
                if env:
                    reports.append(env)
                else:
                    skipped.append(f"{src['name']}: {why}")
    out.mkdir(parents=True, exist_ok=True)
    (out / "reports.json").write_text(json.dumps(reports, indent=2) + "\n")
    (out / "skipped.txt").write_text("".join(s + "\n" for s in skipped))
    print(f"pulled {len(reports)} reports, skipped {len(skipped)}")


def route():
    cfg = config()
    reports = {r["id"]: r for r in json.loads((OUT / "reports.json").read_text())}
    results = [json.loads(l) for l in (OUT / "triage.jsonl").read_text().splitlines() if l]
    outbox = OUT / "outbox"
    filed = {}
    counts = {}
    for res in results:
        verdict, rep = res["verdict"], reports[res["report"]]
        rule = cfg["route"][verdict]
        sink = rule["sink"]
        counts[(verdict, sink)] = counts.get((verdict, sink), 0) + 1
        if sink in cfg.get("sink", {}):
            kind = cfg["sink"][sink]["kind"]
            if res["group"] in filed:
                # A duplicate: add to the item already filed for this group.
                with filed[res["group"]].open("a") as f:
                    f.write(f"\nAlso reported as {res['report']}.\n")
            else:
                path = outbox / sink / f"{res['report']}.md"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(item_text(kind, rule, res, rep))
                filed[res["group"]] = path
        if "reply" in rule:
            path = outbox / "replies" / f"{res['report']}.txt"
            path.parent.mkdir(parents=True, exist_ok=True)
            src = res.get("source", {})
            path.write_text(f"To {src.get('service')} {src.get('ref')}:\n\n{rule['reply']}\n")
    lines = [f"- {v} -> {s}: {n}" for (v, s), n in sorted(counts.items())]
    outbox.mkdir(parents=True, exist_ok=True)
    (outbox / "summary.md").write_text("# Triage summary\n\n" + "\n".join(lines) + "\n")
    print(f"routed {len(results)} results")


def item_text(kind, rule, res, rep):
    """The issue or card that would be created."""
    replay = {k: rep[k] for k in ("start", "ops", "observed", "expected") if k in rep}
    src = res.get("source", {})
    lines = [
        f"# [{res['verdict']}] {res['reason']}",
        "",
        f"Would create: {kind}",
        f"Labels: {', '.join(rule.get('labels', []))}",
        f"From: {src.get('service')} {src.get('ref')} {src.get('url', '')}".rstrip(),
        f"Model: {res['model']}  App: {rep.get('app', {}).get('version', '?')}",
        f"Group: {res['group']}",
        "",
        "## Evidence",
        "",
        *[f"- {e}" for e in res["evidence"]],
        "",
        "## Replay",
        "",
        "```json",
        json.dumps(replay, indent=2),
        "```",
    ]
    if rep.get("note"):
        lines += ["", "## What the user said", "", rep["note"]]
    return "\n".join(lines) + "\n"


NEXT = {
    "code-bug": "The app did something the model doesn't allow. The replay below is a ready-made test case.",
    "expectation-mismatch": "The app followed its rules here, so this is a question about what the rules should be.",
    "model-gap": "The report shows something the model doesn't cover yet, so it can't be judged until the model grows.",
    "malformed": "The attached report couldn't be read. This usually means the app's capture is broken.",
    "version-mismatch": "This report came from another model version, so replaying it here would prove nothing.",
    "cannot-reproduce": "The app, the model and the expectation all agree, so there is nothing to reproduce.",
}


def digest(out=OUT):
    """One comment body and label list per GitHub issue report."""
    cfg = config()
    reports = {r["id"]: r for r in json.loads((out / "reports.json").read_text())}
    results = [json.loads(l) for l in (out / "triage.jsonl").read_text().splitlines() if l]
    folder = out / "digests"
    folder.mkdir(parents=True, exist_ok=True)
    seen = {}
    for res in results:
        rep, src = reports[res["report"]], res.get("source", {})
        if src.get("service") != "github-issue-form":
            continue
        verdict = res["verdict"]
        rule = cfg["route"][verdict]
        lines = [
            MARKER,
            f"**Tribrach triage: {verdict.replace('-', ' ')}**",
            "",
            NEXT[verdict],
            "",
            *[f"- {e}" for e in res["evidence"]],
        ]
        if verdict == "expectation-mismatch" and cfg.get("rules_url"):
            lines += ["", f"What the rules say, in plain English: {cfg['rules_url']}"]
        if verdict == "code-bug":
            replay = {k: rep[k] for k in ("start", "ops", "observed") if k in rep}
            lines += ["", "<details><summary>Replay (test case)</summary>", "", "```json",
                      json.dumps(replay, indent=2), "```", "", "</details>"]
        if res["group"] in seen:
            lines += ["", f"Same trace as #{seen[res['group']]}."]
        else:
            seen[res["group"]] = src["ref"]
        lines += ["", f"<sub>Model {res['model']} · group `{res['group']}` · "
                      "updated on each edit of this issue</sub>"]
        (folder / f"{src['ref']}.md").write_text("\n".join(lines) + "\n")
        labels = list(rule.get("labels", [])) + [f"triage:{verdict}", f"group:{res['group']}"]
        (folder / f"{src['ref']}.labels").write_text(",".join(labels) + "\n")
    print(f"wrote {len(list(folder.glob('*.md')))} digests")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    def arg(name):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None
    out = pathlib.Path(arg("--out")) if arg("--out") else OUT
    if cmd == "pull":
        pull("--offline" in sys.argv, arg("--event"), out)
    elif cmd == "route":
        route()
    elif cmd == "digest":
        digest(out)
    else:
        sys.exit(__doc__)
