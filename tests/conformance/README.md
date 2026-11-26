# Instrument conformance

Every instrument runs these cases for each format version it declares in its
`tribrach-package.toml`, and must produce exactly the expected results.
`python tools/conformance.py` is the reference implementation and runs in
core CI, so the cases stay consistent with each other.

| File | Checks |
| --- | --- |
| `annotations.json` | Reading one comment line: directive, argument or error (`missing-argument`, `extra-argument`, `bad-stamp`, `unknown-directive`); lines that aren't directives give `null` |
| `drift.json` | Comparing host links with the manifest for one owner: `ok`, `drift`, `unstamped`, `unknown`, `symbol-mismatch`, `missing` |
| `replay.json` | Replaying vectors: JSON equality rules, stopping at the first differing step, and what the report names |

Outcome names are shared; diagnostic codes are each instrument's own
(`TRG…` for Go, `TRS…` for Swift). Whatever the code, each diagnostic
should name:

- the Lean definition;
- the reason, in the model's terms (for example "the model has no clock");
- the command that fixes it.

Drift is fixed deliberately: update the model or the host, run the vectors,
then re-stamp with the instrument's stamp command. A stamp is never edited
to silence an error.

Speed: link, purity and drift checks run on every build and should take
well under a second for a typical package. Replay runs with the tests.
