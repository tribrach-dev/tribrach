# Testing guardrails and capture adapters

This plan runs independently of any application. It checks two things: that
guardrails catch what they should and nothing else, and that the capture
contract fits more than one place where code is read.

## 1. Capture adapter conformance

Every adapter must turn the same selection into the same capture
([format](formats/capture.md), [schema](../schema/capture.schema.json)).

- Golden captures live in `tests/captures/valid`; captures that must be
  rejected live in `tests/captures/invalid`. CI validates both.
- Scenarios every adapter must handle:
  - a selection on added or unchanged lines,
  - a selection on deleted lines (the old side of a diff),
  - a selection spanning two hunks,
  - a renamed file,
  - a comment left on an outdated diff,
  - a force-push that moves the branch after the comment.
- Two adapters ship together so the contract can't drift towards one host:
  the CLI (`tribrach guard add --from path:start-end`) and the GitHub pull
  request adapter. A stub editor adapter that only writes a capture file is
  part of the suite.

## 2. Guardrail lab

A separate private repository, `tribrach-dev/guardrail-lab`: a small, neutral
Go service with Lean models and planted incidents, one tagged bad commit per
case.

| Case | Kind | Example |
| --- | --- | --- |
| State rule | behaviour | an item belongs to at most one list |
| Sequence rule | behaviour | a reminder never fires twice within six hours |
| Operation contract | behaviour | deleting a list leaves items unchanged |
| Relation | behaviour | repair twice equals repair once |
| Clock in pure code | code shape | `time.Now()` inside a linked function |
| Store writes outside the repository layer | code shape | a handler writing directly |
| Silent in-memory fallback | code shape | opening the store falls back on error |

For each case:

- the guardrail catches the bad commit (true positive),
- it finds nothing on clean commits (no false positives),
- `tribrach guard test` match counts are stored as goldens,
- a variant of the bug, written differently, is still caught.

Lean side:

- proved guardrails build with no `sorry`,
- one deliberately unprovable guardrail is reported as a finding,
- a checked guardrail's runtime checker flags the bug in a replay.

## 3. GitHub pull request adapter, end to end

In the lab repository, a real pull request and a real
`/tribrach guard <reason>` comment on selected lines. The workflow replies with
the matches and opens a pull request adding the draft guardrail.

Security cases:

- a commenter without write access is ignored,
- shell metacharacters in the comment are never executed,
- a pull request from a fork can't obtain write access,
- an edited or deleted comment doesn't re-trigger a capture.

## 4. Non-expert walkthrough

Someone who doesn't write Lean or analyzer rules plays the architect on three
incidents from highlight to merged guardrail. Record the time taken, the
number of pattern refinements, and every place they got stuck.
