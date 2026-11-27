# Benchmark: diagnosing bugs with and without why-queries

Does asking the logic layer "why?" and "why not?" save an agent effort when
it diagnoses a bug, compared with reading the code and the failing tests?
This folder holds a repeatable benchmark for that question (issue #24). The
full numbers are in [results/RESULTS.md](results/RESULTS.md).

## What it shows so far (2026-11-26)

678 counted runs on three task suites, Claude Code 2.1.332, effort `high`:

- **large and small** (planted faults with failing tests): Claude Sonnet 5.5
  and Claude Opus 5.5 on all 11 tasks (5 repeats on the large suite, 3 on
  the small), and Claude Fable 5.2 on the large suite (3 repeats).
- **hard** (user reports, no failing test, some reports wrong): Sonnet and
  Opus at 5 repeats, Fable at 3.

Findings:

- **Correctness doesn't separate the arms.** Every counted run found the
  right answer in both arms. Harder variants didn't change that either (see
  [Pilots](#pilots)): misleading reports, fixes graded on hidden vectors, a
  bug that needs two edits, and Claude Haiku 5.5 all came out at 100%. At
  this size (up to about 1,150 lines of code and 25 rules) every model can
  read the whole program and specification.
- **Less context, consistently.** With `./why`, the context a session pulled
  in fell for every model on every suite, as the median over tasks of
  (logic median / baseline median):

  | Suite | Sonnet 5.5 | Opus 5.5 | Fable 5.2 |
  | --- | ---: | ---: | ---: |
  | small | 0.69× | 0.70× | - |
  | large | 0.58× | 0.71× | 0.81× |
  | hard | 0.79× | 0.65× | 0.66× |

  It went down on 9 to 11 tasks out of 10 or 11 in every row. Per task, the
  median saving was about 1,300-2,000 tokens on the small and large suites
  and 1,600-4,600 on the hard suite.
- **Output tokens depend on the model and the suite**, from 0.86× (Sonnet,
  large) to 1.16× (Opus, large); on the hard suite 0.91-0.97×.
- **The tool gets used when there is a case to ask about.** On the hard
  suite every logic-arm run called `./why`. On the large suite Sonnet called
  it in 35 of 55 runs; in the fix pilot, where the report names no case,
  Sonnet never called it and read the specification instead.
- **No time saved.** Sessions made about one extra tool call, and wall time
  was flat.
- **The fixed overhead dominates single tasks.** Each request starts with
  roughly 37-40k tokens of system prompt and tool definitions, so per run the
  list-price cost moves only a little (on the hard suite, for example, $0.32
  vs $0.21 per run for Fable, $0.12 vs $0.10 for Opus).

The earlier single-run figure (about 1,500 tokens of reading against about
400 with a why-query) is not reproduced: the saving in context is real and
repeatable, but it is a fifth to two fifths, not three quarters. Because
context carries forward, the saving was expected to matter more in long
sessions; the [long sessions](#long-sessions) below test that, and it
doesn't.

## Long sessions

`shift.py` runs one resumed session through a list of tickets, with the
hidden vectors checked after every ticket. Full numbers are in
[results/SHIFT.md](results/SHIFT.md). Sonnet 5.5, 5 runs per arm, medians:

- **Bug shift** (12 tickets on both services at once, all faults planted
  together, 5 of them reports where the user is wrong).
- **Feature shift** (6 product changes, three per service, each adding
  fields and rules that interact with the existing ones). Before each
  ticket the specification moves to the next version. Hidden vectors come
  from 2,000 generated inputs per service.

Four arms, all given the same ticket text:

- **Markdown spec**: a maintainer-style specification in Markdown
  (`spec_prose/`), with each feature's ticket text appended as a
  "Change" section, which is how a prose spec usually grows.
- **Lean spec**: the Lean specification, no tools.
- **Lean spec + ./why**: as in the single-task suites.
- **Lean spec + ./why + check**: also `./why check <model>`, which runs the
  code against the specification on 1,000 generated inputs (from a seed of
  its own, so never the hidden cases) and prints the first disagreement with
  its why tree ([why_check.py](why_check.py)).

| Shift | Arm | Correct tickets | All hidden pass | Context at end | Tokens read | Cost |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| bugs | Markdown spec | 12/12 | 5/5 | 43,720 | 1.70M | $0.34 |
| bugs | Lean spec | 12/12 | 5/5 | 55,761 | 2.42M | $0.45 |
| bugs | Lean + ./why | 12/12 | 5/5 | 59,188 | 2.88M | $0.51 |
| bugs | Lean + ./why + check | 12/12 | 5/5 | 60,957 | 3.23M | $0.57 |
| features | Markdown spec | 3/6 | 0/5 | 52,481 | 1.59M | $0.40 |
| features | Lean spec | 6/6 | 5/5 | 65,765 | 2.22M | $0.49 |
| features | Lean + ./why | 6/6 | 5/5 | 71,224 | 3.12M | $0.61 |
| features | Lean + ./why + check | 6/6 | 5/5 | 64,435 | 2.66M | $0.53 |

"Tokens read" is the sum of every request's prompt over the session.

Findings:

- **The Lean specification is what separates the arms, on new features.**
  With the Markdown spec, the same two features failed in all 5 runs, and
  no run ended with every hidden vector passing. With either Lean arm, every
  run got all 6 features right. Both failures are interactions the prose
  leaves open:
  - *Quarantine* (51 vectors): "nobody may go through except emergency
    responders" was read as "responders aren't blocked", so responders
    still had to pass training and hours. The Lean rule lets a responder in,
    as in a lockdown.
  - *Service freeze* with tier 0 (3 vectors): the freeze ticket says "a
    hotfix still may", and the tier 0 ticket says a tier 0 hotfix may not
    skip the window. The agents resolved the two differently from the Lean.

  The *sensitive changes* ticket is also marked wrong in every run, because
  grading is strict and the vectors are cumulative. Replaying run 1's edits
  shows that ticket's own change was right, and its 2 failing vectors were
  left over from the freeze ticket. Grading now also reports carried-over
  failures (`carried_over`, `own_ok`). The Markdown specs and the tickets
  were written by the same author as the Lean, so a looser prose spec than
  a careful team would write is possible. That isn't ruled out yet.
- **On bugs, the Markdown spec is as accurate and cheaper**: 12/12 in every
  run, with 30% fewer tokens read than the Lean arm, because the Markdown is
  shorter.
- **The tools cost more than they return in long sessions.** `./why` added
  19% to tokens read on bugs and 40% on features. Its why-trees are added
  on top of reading the code, and every later request carries them. `./why
  check` was used about once per ticket, to confirm a change. It cost less
  than the why-queries on features (2.66M vs 3.12M), but it still came out
  above plain Lean. With every Lean arm at 100%, neither tool had a mistake
  to catch here.
- **The single-task saving doesn't compound.** There, `./why` replaced one
  large "read the whole specification and code" step. In a session that step
  happens once, early, and then everything is in context.

An earlier version of the feature shift had a broken `./why` wrapper (a
shell syntax error), so its logic-arm runs are kept apart in
`results/pilot/features-logic-broken-why-sonnet.jsonl` and not counted.

## Tasks

Three made-up decision functions, each with a specification written as
`Tribrach.Logic` rules ([Bench/](Bench)) and a Python implementation:

| Model | Decides | Spec |
| --- | --- | --- |
| irrigation | which garden valves to open this hour | [Irrigation.lean](Bench/Irrigation.lean) |
| library | which requested items a member may take home | [Library.lean](Bench/Library.lean) |
| notify | which channels an event goes out on | [Notify.lean](Bench/Notify.lean) |

Each implementation comes in two sizes, with the same logic:

- **small** ([host/](host)): one module of 40-60 lines. The whole program
  fits in a single read.
- **large** ([host_large/](host_large)): a package of 7-10 modules (160-290
  lines) with the decision spread over several files and code that has
  nothing to do with it (receipts, history, message text, settings loading).

Test vectors ([vectors/](vectors)) are 30 seeded random inputs per model
plus a few boundary cases ([gen_inputs.py](gen_inputs.py)). Their expected
decisions come from the Lean specification (`lake exe why expect`), not
from the Python code.

**Planted faults** ([faults.json](faults.json), [faults_large.json](faults_large.json)):
the same nine logical faults in both sizes, each a single edit with a known
location.

| Task | Category | Failing vectors |
| --- | --- | ---: |
| irr-stale-constant | stale constant (a threshold differs from the spec) | 1 |
| irr-dropped-frost | dropped condition | 1 |
| irr-wrong-comparison | wrong comparison (`<=` for `<`) | 1 |
| lib-swapped-branch | swapped branch | 1 |
| lib-dropped-hold-owner | dropped condition | 3 |
| lib-wrong-comparison | wrong comparison (`>` for `>=`) | 1 |
| lib-encoding-tier | encoding mismatch (the host's name for a value differs from the spec's) | 2 |
| ntf-swapped-branch | swapped branch | 8 |
| ntf-dropped-verified | dropped condition | 2 |

**Questions** ([questions.json](questions.json)): two "why didn't this
happen?" questions about correct code, such as "a security event reached
the user on no channel; for each channel, why not?".

`python bench.py check` confirms that the clean code passes every vector,
that each fault fails at least one, and that the questions' cases pass.

### Report suite (`hard`)

Two bigger made-up models, building access ([Access.lean](Bench/Access.lean),
23 rules) and a deploy gate ([Deploy.lean](Bench/Deploy.lean), 26 rules),
with Python packages of about 720 and 430 lines ([host_hard/](host_hard)),
including code that looks relevant but isn't (a renewal reminder, a burn
alert, a report window).

Each task ([tasks_hard.json](tasks_hard.json)) is a user report about one
situation, given as a test case without expected decisions. In seven the
code has a planted fault; in three the code is right and the user is wrong.
Every report also carries the user's own guess, which is always wrong. No
test fails: the tests are filtered to the vectors no fault changes, so the
report is the only evidence. The session answers `bug` or `no_bug`; a bug
answer must also name the file and match the fault's cause.

### Fix suite (`fix`)

The same two packages, but the report is vague and names no case ("now and
then a change goes to the canary even though its service looks healthy").
The session must fix the code, or leave it alone if the user is wrong, and
is graded on 800 hidden vectors per model that it never sees
([gen_inputs.py](gen_inputs.py) `*_wide`, dense in boundary values). One
fault needs edits in two places; `bench.py check` confirms that fixing
either alone still fails hidden vectors. In the logic arm, `./why --cases`
answers for cases the session writes itself.


## Pilots

Calibration runs, kept in [results/pilot/](results/pilot) and not counted
above. Each was one repeat of every task in both arms.

| Pilot | Model | Runs | Correct | ./why used | Context, logic / baseline |
| --- | --- | ---: | ---: | ---: | ---: |
| hard, plain reports (v1) | Sonnet 5.5 | 20 | 20 | 10/10 | - |
| hard, reports with a wrong guess (v2) | Sonnet 5.5 | 20 | 20 | 10/10 | - |
| hard (v2) | Haiku 5.5 | 20 | 20 | 10/10 | 0.80× (10/10 down) |
| fix | Sonnet 5.5 | 18 | 18 | 0/9 | 1.15× (2/9 down) |
| fix | Haiku 5.5 | 18 | 18 | 9/9 | 0.98× (5/9 down) |

The v2 report text is the one in tasks_hard.json; v1 is kept beside the
pilot results.

## Arms

Each run is one fresh, headless Claude Code session (`claude -p`) in a new
folder with a random name, holding only that task's files: `host/` (with the
fault planted), `spec/` (the Lean model), `tests/`, and `run_tests.py`.

- **baseline**: those files.
- **logic**: the same files plus `./why`, a command that answers from the
  specification for any test case: the expected decisions with their why
  trees (`Why.explain`, each re-checked by `Why.check`), "why not?" for a
  decision that doesn't follow (`Tribrach.Logic.whyNot`), and the given facts.

The prompts are fixed and generated by `prompt_for` in [bench.py](bench.py).
The logic arm's prompt adds a description of `./why` and one sentence saying
it is usually the quickest way to see which conditions decide a failing case.
Nothing else differs. Bug tasks end with the session writing `answer.json`
(file, line, cause); question tasks with one sentence per item asked about.

Sessions get only the Bash, Read, Grep, Glob, Write and Edit tools, no MCP
servers and no web access, at a pinned effort level. Arm order alternates
between repeats so prompt-cache warmth doesn't favour one arm.

## Metrics

From each session's `stream-json` transcript:

- **Output tokens**: everything the model wrote, including thinking.
- **Context added**: the size of the last request's prompt minus the first
  one's. The first request holds only the fixed system prompt, tool
  definitions and the task, so this is what the work itself pulled into
  context: file contents, test output, `./why` output and the model's own
  turns. It leaves out the fixed overhead, which is the same in both arms.
- **Tool calls** and **wall time**.
- **Correct**: graded automatically from `answer.json`. For a bug, the
  answer must name the planted file, and its cause must match the fault's
  `cause_pattern` (for example `frost|temperature|cold|freez` for the dropped
  frost check). **Line right** counts answers whose line is within one of the
  planted lines; it is reported separately because sessions often miscount
  lines after printing several files at once. For a question, each item's
  answer must name the deciding condition (a pattern per item in
  `questions.json`). `summarize` grades every stored answer again with the
  current rules.
- **List-price cost**: Claude Code's API-equivalent estimate for the run,
  which depends on prompt-cache warmth; on a subscription it is only a
  guide to relative usage.
- **Used ./why**: how many logic-arm runs called it at all.

Every run's record, including the list of tool calls and the answer, is in
`results/runs-<suite>-<model>.jsonl`. Full transcripts are not committed (they repeat the
system prompt on every turn), but `bench.py` keeps them in
`$WHY_BENCH_WORK/transcripts` for anyone rerunning it.

Runs whose tool calls touched paths outside their own folder are listed at
the end of RESULTS.md.

## Reproducing

```sh
lake build                                     # builds the `why` tool
mkdir -p /opt/why-bench && cp .lake/build/bin/why /opt/why-bench/why
python3 bench.py check
python3 bench.py run --suite large --model claude-sonnet-5-5 --reps 3
python3 bench.py run --suite hard --model claude-sonnet-5-5 --reps 5   # or --suite fix
python3 bench.py summarize                     # writes results/RESULTS.md
python3 shift.py run --model claude-sonnet-5-5 --arms prose,baseline,logic,check --reps 5
python3 shift.py --shift features run --model claude-sonnet-5-5 --arms prose,baseline,logic,check --reps 5
python3 shift.py summarize                     # writes results/SHIFT.md
```

`bench.py run` uses whatever account the local `claude` command is signed
in to. The tool is installed outside the repository so that a session can't
follow it back to the answer key; set `WHY_BENCH_ENGINE` to put it elsewhere.

## Limits

- The models are small and made up, and all host code is Python. The large
  suite is still small next to a real codebase.
- Facts come from the specification's `encode` step. Host-emitted facts
  (the issue's later step) aren't covered yet.
- The long sessions use one model (Sonnet 5.5) and two services; the
  Markdown specs were written by the benchmark's author, not by an
  independent team.
- Only Claude Code sessions are measured; other agents may use the tool
  differently.
- A session can read anything on the machine it runs on. Prompts tell it to
  stay in its folder, and stray paths are reported, but nothing enforces it.
