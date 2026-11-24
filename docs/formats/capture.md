# Capture format (version 1)

A capture is what an adapter produces when someone highlights code and asks
Tribrach to make a guardrail from it. Adapters (CLI, pull requests, editors,
chat tools) only produce captures; everything after that is the same.

## Rule that keeps adapters simple

Line numbers always refer to the file **as it exists at `commit`**. An adapter
never records diff positions or "left/right side". For a selection on deleted
lines, the adapter records the base commit and the old path. This makes
deleted lines, renamed files and outdated comments ordinary cases.

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Always `1`. |
| `repo` | yes | `{ "host": "github.com", "name": "owner/repo" }`. |
| `commit` | yes | Full 40-character commit SHA the line numbers refer to. |
| `path` | yes | File path at `commit`, relative to the repository root, `/`-separated. |
| `ranges` | yes | One or more `{ "start": n, "end": m }`, 1-based and inclusive, sorted and non-overlapping. Several ranges cover a selection that spans hunks. |
| `snippet_sha256` | yes | SHA-256 of the selected lines joined with `\n`, so a resolver can tell if it fetched different text. |
| `note` | yes | Why this is a problem, in the reporter's words. Treated as data, never executed. May be empty. |
| `kind` | yes | `behaviour`, `code-shape` or `unknown`. |
| `source` | yes | `{ "adapter": "cli" | "github-pr" | "<name>", "url": "<optional link back>" }`. |
| `reporter` | no | Login or name of the person who made the capture. |
| `created_at` | yes | RFC 3339 timestamp. |

Unknown fields are rejected, so adapters can't drift silently.

## How awkward cases map

| Case | What the adapter records |
| --- | --- |
| Added or unchanged lines | Head commit, current path. |
| Deleted lines | Base commit, path before the change. |
| Selection across two hunks | Two ranges. |
| Renamed file | The path at the recorded commit. |
| Comment on an outdated diff | The commit the comment was made on (GitHub's original commit), not the new head. |
| Force-push after the comment | Unchanged: the recorded commit stays reachable through the comment. |
