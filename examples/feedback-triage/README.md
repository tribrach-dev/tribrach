# Feedback triage

A user taps "this is wrong". Instead of a vague bug report, the app attaches
the operations they performed, the state it showed, and what they expected.
Replaying that against the model sorts every report into one of three groups:

| Triage | Meaning | Goes to |
| --- | --- | --- |
| `code-bug` | The app did something the model doesn't allow, or broke a rule | Engineering, with a ready-made test case |
| `expectation-mismatch` | The app followed the rules exactly; the user expected something else | The architect: a spec question, maybe a rule change or a guardrail |
| `cannot-reproduce` | The report doesn't replay, or nothing differs | A dashboard, to spot missing context |

```sh
lake build
lake exe triage reports.json
```

`reports.json` holds five sample reports with the triage each should get; the
command exits non-zero if any are sorted differently. The model is a tiny
to-do list (add, complete, remove) whose rule is that item ids are unique. The
rule is checked here rather than proved; see `examples/counter` for proofs.

In a real app the report contents come from the model's privacy labels, so a
user sees exactly what will be sent, and only operation names and model state
leave the device.
