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

## Rule cards

[RULES.md](RULES.md) explains each rule in plain English, with situations it
allows and the realistic bugs it catches (with what the buggy app would show),
a list of bugs no rule catches, and a "Did you know?" section of questions answered by the
shortest example the search finds (for instance, whether a ticked item can end
up unticked). Everything on the page is generated from the model:

```sh
lake exe cards --write RULES.md
```

CI runs `lake exe cards --check RULES.md`, which fails if the page is out of
date, if the model breaks a rule, if a rule never applies, or if a rule never
says no to any outcome in its stated domain. A rule that catches none of the
known bugs is reported as a coverage finding but doesn't fail the build: it
says something about the bug list, not the rule. Fixture rules check that
each finding is reported as intended. The examples are checked on every small list,
not proved for all lists.
