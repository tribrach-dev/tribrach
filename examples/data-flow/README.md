# Data flow: does personal data reach telemetry?

The first use of Tribrach's logic layer (`Tribrach.Logic`, a small Datalog
engine). A made-up note-taking app is described as facts ("email is sent to
account", "crash_report is a telemetry event"), and three rules define what
"ends up in" and "reaches telemetry" mean. Questions are queries:

```sh
lake build
lake exe why
```

Every answer comes with a plain-English why tree, for example:

- personal data email reaches telemetry event crash_report, because:
  - email is personal data (given)
  - email ends up in crash_report, because email is sent to account, which
    ends up in crash_report
  - crash_report is a telemetry event (given)

Two properties matter:

- **"No" is a real no.** Datalog always finishes on a finite program, so when
  the engine reaches its fixpoint a missing answer means "does not follow",
  not "not found yet". The exe fails if the engine ran out of rounds.
- **Answers are checked separately.** The engine only suggests. `Why.check`
  is a much smaller checker that re-verifies each tree against the facts and
  rules without the engine. Larger external engines can later plug in by
  producing trees the same checker accepts.

In a real project, the language instruments would extract the facts from
code, so architects and product managers can query the system without
reading it.
