# Benchmark: diagnosing bugs with and without why-queries

Does asking the logic layer "why?" and "why not?" save an agent effort when
it diagnoses a bug, compared with reading the code and the failing tests?
This folder holds a repeatable benchmark for that question (issue #24). The
full numbers are in [results/RESULTS.md](results/RESULTS.md).

## What it shows so far (2026-11-26)

368 runs: Claude Sonnet 5.5 and Claude Opus 5.5 on all 11 tasks (5 repeats
on the large suite, 3 on the small), and a 4-task, 2-repeat sample of Claude
Fable 5.2. Claude Code 2.1.332, effort `high`.

- **Correctness doesn't separate the arms.** Every run found the right cause
  in both arms, so these tasks are too easy to show a difference there.
- **Less context, consistently.** With `./why`, the context a session pulled
  in to do the work fell by a median of about 30% per task for every model
  and both sizes (large suite: Sonnet 0.58×, Opus 0.71×; small: 0.69× and
  0.70×), and went down on 10 or 11 of the 11 tasks in each case. In
  absolute terms that is roughly 1,100-2,800 tokens per task (medians).
- **Output tokens depend on the model.** Sonnet wrote less with `./why`
  (0.86× on the large suite, lower on all 11 tasks); Opus wrote more (1.16×,
  lower on 2 of 11).
  The Fable sample wrote less (0.86×), but it is 4 tasks at 2 repeats.
- **Sonnet often skipped the tool.** It called `./why` in 35 of 55 large-suite
  runs and 15 of 33 small ones; Opus in 51 of 55 and 31 of 33. The context
  figures above include the runs that didn't use it.
- **No time saved.** Sessions made about one extra tool call (the `./why`
  query), and wall time was flat.
- **The fixed overhead dominates.** Each request starts with roughly 37-40k
  tokens of system prompt and tool definitions, so per run the list-price
  cost barely moves (for example $0.09 vs $0.08 for Opus on the large suite).

The earlier single-run figure (about 1,500 tokens of reading against about
400 with a why-query) is not reproduced: the saving in context is real and
repeatable, but it is about a third, not three quarters, and it doesn't
carry over to output tokens on every model. Harder tasks (larger code, faults
spread over several files, or questions where code reading goes wrong) are
the next step before quoting anything stronger.

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
python3 bench.py summarize                     # writes results/RESULTS.md
```

`bench.py run` uses whatever account the local `claude` command is signed
in to. The tool is installed outside the repository so that a session can't
follow it back to the answer key; set `WHY_BENCH_ENGINE` to put it elsewhere.

## Limits

- The models are small and made up, and all host code is Python. The large
  suite is still small next to a real codebase.
- Facts come from the specification's `encode` step. Host-emitted facts
  (the issue's later step) aren't covered yet.
- Only Claude Code sessions are measured; other agents may use the tool
  differently.
- A session can read anything on the machine it runs on. Prompts tell it to
  stay in its folder, and stray paths are reported, but nothing enforces it.
