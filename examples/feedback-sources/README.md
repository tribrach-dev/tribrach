# Feedback sources

How feedback gets from the services people already use to Tribrach triage
and back, with offline stubs that CI runs end to end.

```sh
python3 feedback.py pull --offline     # fixtures/ -> out/reports.json
lake exe triage --json out/reports.json > out/triage.jsonl
python3 feedback.py route              # -> out/outbox/
```

## Pull: from a service to a report envelope

Each adapter finds the report the app attached and wraps it in a
`tribrach.report.v1` envelope (`schema/report.schema.json`). It records where
the report came from (service, ticket id, link), the app version, and the
privacy labels the user saw. Nothing else from the payload is kept: names,
emails and other ticket fields stay in the service.

| Fixture | Shaped like | Where the report is |
| --- | --- | --- |
| `github-issue-form.json` | Issues created from an issue form | A fenced `tribrach-report` block in the body |
| `crash-reporter-feedback.json` | A crash reporter's user-feedback event | An attachment named `tribrach-report.json` |
| `helpdesk-tickets.json` | A helpdesk ticket | An attachment named `tribrach-report.json` |

The fixtures are invented and minimal, not copies of any service's real
payloads. A ticket with no report attached is skipped and listed in
`skipped.txt`.

## Triage

`lake exe triage --json` (from `Tribrach.Triage`, with the to-do model from
`examples/feedback-triage`) prints one `tribrach.triage.v1` result per report
(`schema/triage.schema.json`): verdict, reason, evidence, the source passed
through, and a `group` key that is the same for duplicate reports.

## Route: from a verdict to an action

`tribrach-triage.toml` maps each verdict to a destination, labels and an
optional reply to the original ticket:

- code bugs and model gaps become issues, with the replay as a test case;
- expectation mismatches become product cards;
- version mismatches are held, with a reply;
- cannot-reproduce is only counted.

Duplicates (same `group`) are added to the item already filed. Here,
"filing" writes what would be created into `out/outbox/`, and CI compares
everything with `expected/`.

## Issue digests

`python3 feedback.py digest` writes, for each report that came from a GitHub
issue, the comment a bot would post (`out/digests/<issue>.md`) and its
labels (`<issue>.labels`). Each digest has:

- the verdict and what it means for the reporter;
- the evidence;
- for a code bug, the replay as a ready-made test case;
- for an expectation mismatch, a link to the rule cards;
- "Same trace as #12" when another issue has the same `group`.

The labels are the route's labels plus `triage:<verdict>` and
`group:<key>`, so duplicates can be found across runs.

[`workflows/triage-issues.yml`](workflows/triage-issues.yml) is a template
for an app's repository. It runs on `issues: [opened, edited]` with only the
built-in `GITHUB_TOKEN` (`issues: write`). It reads the issue from the event
file with `pull --event`, restores the Lean build from the cache that main's
CI fills, triages, and then:

- keeps a single digest comment up to date, found by its hidden marker;
- adds the labels;
- links earlier issues that carry the same group label.

The issue body is treated as untrusted data: it is parsed as JSON and never
interpolated into a shell command. Only GitHub-made actions are used. CI
here runs the same path on `fixtures/issue-event.json`.

## Access

`tribrach-triage.toml` never holds secrets. Each source and sink names the
environment variable that holds its token (`token_env`), with the least
scopes it needs noted beside it:

- **Locally:** copy `.env.example` to `.env`, which is gitignored.
- **In CI:** use the secret store. A scheduled workflow that pulls, triages
  and files issues can use the built-in `GITHUB_TOKEN` for GitHub.

Live connectors (API clients, webhooks with signature checks) are not part
of this example. Without `--offline`, `pull` only checks that the variables
are set.
