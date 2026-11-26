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

- personal data location reaches telemetry event usage_event, because:
  - location is personal data (given)
  - location ends up in usage_event, because location is sent to
    note_metadata, which is sent to usage_event
  - usage_event is a telemetry event (given)
  - nothing says location is removed before usage_event is sent

Two properties matter:

- **"No" is a real no.** Datalog always finishes on a finite program, so when
  the engine reaches its fixpoint a missing answer means "does not follow",
  not "not found yet". The exe fails if the engine ran out of rounds.
- **Answers are checked separately.** The engine only suggests. `Why.check`
  is a much smaller checker that re-verifies each tree against the facts and
  rules without the engine, and `Why.check_sound` proves in Lean that
  anything it accepts really follows. Larger external engines can later plug
  in by producing trees the same checker accepts.
- **"Unless" rules.** The telemetry rule says "unless the data is redacted
  on the way". Email reaches the crash report, but it's removed first, so
  only location is flagged, and the why tree says "nothing says location is
  removed before usage_event is sent".

In a real project, the language instruments would extract the facts from
code, so architects and product managers can query the system without
reading it.
