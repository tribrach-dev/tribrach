# Roadmap

## Where static analysis lives

Each language instrument owns its static analyzer, built on that language's
native tooling. The core owns what the analyzers share, so they report the
same things in the same way.

| Layer | Owns |
| --- | --- |
| Core (`tribrach`) | Annotation grammar (`//tribrach:link`, `//tribrach:pure`, `//tribrach:stamp`), manifest and stamp schema, vector format, claim files, one diagnostic output format, the `tribrach check` runner |
| `tribrach-go` | `go vet` analyzer: links, purity, drift, stamps; vector replay |
| `tribrach-swift` | SwiftSyntax analyzer, SwiftPM build and command plugins: links, purity, drift, stamps; vector replay |
| `tribrach-data` | Stored-data rules, operation replay against real stores, migrations; adapters per store |

## v0.1: verified SwiftData models and migrations

1. Core shared formats in Lean: manifest, vectors, stamps, diagnostics.
2. `tribrach-swift`: link and drift checks, replay of generated operation
   sequences against an in-memory SwiftData store.
3. `tribrach-data` with the SwiftData adapter:
   - Integrity rules on stored data: references, cardinality, uniqueness,
     value domains, ordering. A generated checker runs at launch, after
     migrations and over fixtures; each rule declares repair or flag.
   - Every write operation proved to keep the rules and replayed against the
     store, including what deletes take with them.
   - External references (photo library items, files, cloud objects) that can
     disappear, with a repair proved safe to run twice.
   - Migrations: data contracts per schema version, golden records, rollback
     challenge.
4. Neutral demo: a to-do app across three schema versions with one
   deliberately broken migration that Tribrach catches.
5. Agent-ready CLI (see "Agentic coding" below).
6. Rules file for data rules (see "Rules for architects" below).

## v0.2

- `tribrach-go`, and the Firestore and SQLite adapters for `tribrach-data`.
- Failure behaviour: no silent fallback when a store can't open, save errors
  surfaced, interrupted writes leave valid data.
- Query contracts: queries checked against the model, catching queries that
  can never match.
- Export and import round trip.
- Telemetry awareness and suggestions (see below).
- Pattern guardrails and `tribrach guard add` (see "Rules for architects").
- JSON Schema and OpenAPI exporters and generated DTOs (see "Contracts as the source of DTOs").

## v0.3

- Sync and merge: offline edits on two devices converge, and the rules hold
  after merging.
- Access rules: Firestore security rules and row-level security proved per
  user, with vectors for the rules emulator.
- Deletion and retention: deleting an account provably leaves nothing behind.
- Telemetry privacy flow: personal values traced into event arguments.
- Feedback captures: user reports as operation-sequence captures (see "User feedback").

## Telemetry

The model knows which operations, failures, repairs and migrations matter, so
Tribrach can tell you what your telemetry covers and where to add events.

- **Core:** an event vocabulary generated from the model (operation outcomes,
  rule violations, repairs, migration steps), privacy labels on model fields
  (`personal`, `pseudonymous`, `public`), and per-operation emit policy
  (`required`, `suggested`, `none`). Delivery goes through a small sink
  interface with one first-party adapter: OpenTelemetry.
- **Instruments:** recognise the project's emit calls (listed once in config),
  tie each to the model element it observes, report coverage, and suggest
  emit points.

### Static analysis behaviour

| Level | Fails | Checks |
| --- | --- | --- |
| Error | Always | A `personal` value reaches an event argument; an event name not in the vocabulary or with a stale stamp; an emit inside linked pure code |
| Warning | With `--strict` (use on main) | An operation with emit policy `required` has no event; a rule-violation checker isn't wired to a sink; an event that matches nothing in the model |
| Suggestion | Never | Ranked emit points with a payload template of non-personal fields; emits in hot loops; sampling hints |

- Suggestions point at the shell call site of the linked operation, never the
  pure core. Go offers them as editor fixes; Swift shows them as build notes.
- Ranking: refusals and failures, user-visible decisions, irreversible actions,
  repairs and flagged rows, migration steps, lost external references.
- Adoption on an existing codebase starts from a baseline file, so only new
  findings fail.
- Suppressions use `//tribrach:ignore <check> <reason>`; a reason is required
  and suppressions are counted in the report.
- Output is SARIF, so findings appear on pull requests through code scanning,
  plus a coverage report as a build artifact.
- Analysis is offline and deterministic, and runs per package so it stays fast.

## Agentic coding

Tribrach lets people review a few lines of rules while agents write the code,
and gives agents a fast, exact check to work against. It is CLI-first: the
same commands serve people, CI and agents.

- **v0.1:** every check and query is a CLI subcommand with stable diagnostic
  codes, `--json` and SARIF output, and suggested fixes; queries include
  `tribrach rules --file <path>` and `tribrach explain <code>`. No hidden
  state.
- **v0.1:** generated agent instructions (an AGENTS.md or CLAUDE.md section,
  or a skill) built from the manifest: which functions are linked, keep them
  pure, never hand-edit vectors, rule changes need a human.
- **v0.1:** CI labels any pull request that changes rules, claims or vectors
  as a spec change needing human approval. `sorry` and new axioms stay banned.
- **Later, optional:** a thin MCP wrapper over the same CLI, shipped as a
  separate package for hosts without a shell. It adds no capability the CLI
  lacks and is never required; it is one of the contributed capture adapters.

## Rules for architects

Most architects won't write Lean, so Tribrach gives them two ways in. Both
compile to Lean or to analyzer rules, so there is still one source of truth.
The rules file stays small on purpose; it is not a general rules engine.

### Rules file (v0.1, data rules first)

A short declarative file (TOML or YAML) for the common shapes:
relationships and cardinality, required fields and value ranges, uniqueness,
ordering, state machines (states and allowed transitions), and migration
contracts per version. Tribrach generates the Lean model and proof
obligations; most close automatically, and a person or agent finishes the rest
with Lean's kernel checking the result. `tribrach explain` renders every rule
in plain English. Raw Lean remains available. Edits are spec changes and need
approval.

### Guardrails (v0.2)

- **Code-shape guardrails** are lint rules enforced by the instruments'
  analyzers (for example: no clock reads in linked pure code; only the
  repository layer writes to the store; never fall back to an in-memory store).
- **Behaviour guardrails** are Lean rules over operation sequences (for
  example: an alert never fires twice within six hours; deleting a location
  never deletes photos). Each is labelled proved or tested.
- **Incident to guardrail:** `tribrach guard add` takes the pattern and the
  failing example that inspired it, confirms the guardrail catches the
  example, then enforces it. Each guardrail records an owner, a reason and a
  level (error, warning, suggestion); existing violations go in the baseline.
  `tribrach guard test` shows every match across the repository so the
  pattern can be tightened or loosened.

### What a guardrail is in Lean

Behaviour guardrails are theorems about the model; they never add behaviour.
Code-shape guardrails are analyzer rules, recorded in Lean only as claims.

Behaviour guardrails take one of four shapes:

1. **State rule:** always true of the data (a photo belongs to at most one
   location). Proved by every operation keeping it.
2. **Sequence rule:** true across operations (an alert never fires twice within
   six hours). The model tracks the needed history, turning it into a state
   rule.
3. **Operation contract:** what one operation must not touch (deleting a
   location leaves photos unchanged).
4. **Relation:** between operations (repair twice equals repair once; migrate
   then roll back returns the original; merge order doesn't matter).

The captured incident becomes a concrete operation sequence, and Lean checks
the guardrail rejects it.

Each guardrail's promise is recorded in the claim file at one of three levels:

| Level | Promise |
| --- | --- |
| Proved | Holds for every input to the model; no runtime cost |
| Checked | Stated in Lean, not yet proved; tested on generated cases and watched by a runtime checker |
| Linted | Code-shape rule; no matching pattern in linked code |

If a guardrail can't be proved because the model allows the bad behaviour,
that is a finding: change the model and code (a spec change), or drop the
guardrail.

### Capturing examples from where people read code (v0.2)

Code is read in many places (pull requests, editors, chat), so capture is a
small adapter contract, not one integration:

- **Core:** a capture format (repository, commit, path, line range, note,
  guardrail kind) and `tribrach guard add --from <capture>`.
- **First adapter: GitHub pull requests.** A reviewer selects lines in the diff
  and comments `/tribrach guard <reason>`. A workflow in the repository reads
  the path, line range and commit from the event, runs `guard add` and
  `guard test`, replies with the matches, and opens a pull request adding the
  draft guardrail, so adopting it goes through normal review. Only commenters
  with write access can trigger it, and comment text is never executed.
- **Contributed adapters:** editor commands (VS Code, Xcode, JetBrains), other
  forges, and the optional MCP wrapper for chat-based tools. Each only
  produces the capture format.
- Tribrach itself stays deterministic: generalising a snippet into a pattern
  is proposed by a person or an agent, never by a model inside Tribrach.

## Trusting the rules-file generator

Lean's kernel checks the proofs; the risk is the translation from rules file
to Lean. Tribrach narrows it four ways:

1. The generator is written in Lean. Each rule shape has a meaning function,
   and Tribrach proves the generated rule equals it, so only the parser is
   trusted (and it is round-trip tested).
2. Every rule carries at least one valid and one invalid example, checked
   against the generated rule.
3. Vacuity and contradiction checks: warn when a rule can never be broken or
   when no valid state exists.
4. `tribrach explain` renders English from the generated Lean, which is
   committed and reviewed like a lockfile.

## Contracts as the source of DTOs (v0.2)

A Tribrach contract is the source; DTOs, schemas and validators are generated
views of it. Tribrach exports to existing schema ecosystems rather than
competing with them.

- **Exporters:** JSON Schema and OpenAPI from Lean definitions, with a proof
  (or exhaustive check) that the exported schema accepts exactly the values
  the Lean type and its rules accept. First test: the capture format, whose
  hand-written schema in `schema/` becomes generated. Started:
  `Tribrach.Schema` and `examples/capture-schema` generate the capture
  schema, and the Lean checker, the regexes and the goldens are checked
  against each other in CI. The proof of exactness, sums (`oneOf`), the
  mapping layer and OpenAPI come next, driven by a parking example (meters
  and payments services and a Swift client).
- **Generated boundary types:** Go and Swift DTOs plus decoders that run the
  generated checker, so invalid data is rejected at the edge. DTOs stay plain
  data.
- **API versioning:** the data-contract fields (forward reads, older writers,
  rollback) apply to request and response types, so "a new server accepts old
  clients" is proved, not assumed.
- **Mapping layer:** wire details (field numbers, null versus missing, naming
  style, date formats) live in a thin mapping next to the model, not in the
  model itself.
- **Later:** importing existing OpenAPI or protobuf definitions as a starting
  model. Only boundary types with rules worth promising need to be contracts.

## User feedback

The model knows what the app should have done, so user feedback can be
replayed instead of guessed at. Library: `Tribrach.Triage`; example:
`examples/feedback-triage`.

- **Reports with context:** when a user says "this is wrong", the app attaches
  the recent operation names, the rules in play, the model stamp and the app
  version. Privacy labels decide what may be included, and the user sees
  exactly what will be sent.
- **Triage by replay** (in the library: any `Model` plus a small `Subject`
  adapter):
  - `malformed`: the capture itself is broken.
  - `version-mismatch`: the report was made against another model version.
  - `model-gap`: the report shows an operation or state field the model
    doesn't have.
  - `code-bug`: the app broke the model or a rule; it arrives with a test
    case.
  - `expectation-mismatch`: the app followed the rules but the user expected
    otherwise. This is a spec question, shown with `tribrach explain`.
  - `cannot-reproduce`: nothing differs.
- **Next for triage:**
  - Replay older-version reports through a migration when one exists.
  - Relational models, where a report records each step's outcome (done,
    refused, failed).
- **Disagreement per rule:** counting reports per rule shows which rules
  users push back on, a product signal rather than a bug signal.
- **Same plugin shape:** feedback is a capture of an operation sequence
  rather than code lines (a new capture kind, v0.3), so an expectation
  mismatch can feed `tribrach guard add` or a rule change. Delivery goes
  through adapters (issue trackers, email, an app's own backend).

## Rule cards

The real risk in a spec is proving the wrong statement. Rule cards let someone
who doesn't read Lean check what a rule means. Prototype:
`examples/feedback-triage` (`lake exe cards`, [RULES.md](../examples/feedback-triage/RULES.md)).

- **Each card shows** the rule in plain English, situations it allows, and the
  realistic bugs it catches, with what a buggy app would show. The page also
  lists bugs that no rule catches, and a "Did you know?" section answers
  questions with the shortest example found. Everything is generated, and CI
  fails if the page is stale, the model breaks a rule, or a rule catches no
  known bug. The cards are checked over small cases, not proved.
- **Cards change rarely and on purpose.** Feature work builds to the spec, so
  its cards don't move. Each layer has its own job:
  - *Planning* is where cards change. `tribrach cards --compare main` previews
    new cards, flipped answers and changes in which bugs are caught. Decisions
    are pinned, and a small spec PR lands before the feature work.
  - *While coding* (a person or a coding agent), static analysis is the
    layer that keeps code aligned with the spec: the instruments' analyzers
    report stable codes (link, purity, drift, guardrails) in the editor, in
    `--json`/SARIF and in an agent's own loop, so most drift is fixed before
    a PR exists. Cards are not part of this loop.
  - *At PR time*, cards are the human-readable layer. CI posts a short
    summary (job summary or one PR comment): the cards whose rules this PR's
    code touches, found through the link manifest, so a reviewer sees in
    plain English which promises the change sits under. Any flipped answer
    goes at the top and fails CI ("this PR changes the spec") unless the PR
    carries the spec-change label. Cards for a brand-new area are expected
    and get listed for the next planning review.
  - *Triage* groups expectation-mismatch reports by card, so pushback from
    users shows up against the rule it's about.
- **Pins:** a plain-text file next to the cards, with an expected answer per
  question id and "should not happen" per example id. Canvases only write to
  this file. The first canvas is a GitHub PR comment (`/tribrach pin`,
  `/tribrach flag`), with the same capture adapter shape as code highlighting
  and a new capture kind, "card reaction". A clickable HTML page comes later.
- **At scale:**
  - stable ids;
  - regenerate only cards whose part of the model changed;
  - areas with owners;
  - a "needs a decision" queue, riskiest first;
  - a baseline that accepts every current answer on adoption;
  - question templates per rule shape, with implied answers dropped;
  - a health summary per area.

## Reasoning engines

Logic programming gives Tribrach a way to *ask* the spec questions, not only
check it. One rule runs through all of it: **engines suggest, Lean checks.**
A search engine, even a large external one, only proposes an answer: an
example, a derivation, a candidate rule. Tribrach reports it only after a
small checker has re-verified it. "Yes" answers come with an example that is
cheap to check. "No" answers are either complete (Datalog at its fixpoint) or
proved once in Lean; anything else is labelled as bounded.

- **Logic layer (started):** `Tribrach.Logic` is a Datalog engine with why
  trees, plus an independent checker, `Why.check`, proved sound in Lean
  (`Why.check_sound`). Rules can say "unless" over given facts. The example is
  `examples/data-flow`. Facts come from the instruments (code facts such as
  "this field is sent to this event") and from the model; rules come from
  packs and architects.
- **Goal-directed search.** Search backwards from a question with tabling
  (remembering states it has seen) and iterative deepening (so the shortest
  example comes first). It replaces brute force in rule cards, and doubles as
  a test budget: keep one test per distinct reason a goal can be reached,
  plus near misses. Goals are ranked by risk:
  - rules users push back on;
  - pinned answers;
  - rules whose linked code a PR touches.
- **"Why" and "impact" for people and coding agents.**
  - `tribrach why --json` returns the shortest trace, the rule and the linked
    function behind an analyzer error or an answer.
  - `tribrach impact <symbol>` lists the rules and cards that depend on a
    function before it is edited.

  An agent calls these tools instead of simulating code in chain of thought.
  To measure it, seed known bugs (the rule-card mutants) and compare an
  agent's turns and tokens to a correct fix, with and without `why`.
- **Abduction in feedback triage.** Given a state a user reports, list the
  action sequences that could produce it. Some "cannot reproduce" reports
  become "explained by …". When no sequence without a given action produces
  the state, it's a code bug, even without logs.
- **Query language for architects and product managers.** They query the
  spec, not the code. Questions about sequences ("can a user get an alert
  after cancelling?") use goal-directed search. Questions about code
  structure ("where does personal data flow?") use Datalog over facts the
  instruments emit. Plain-language questions can be translated by an LLM,
  because every answer comes back with a checked example.
- **Brownfield on-ramp.** Mine candidate rules from what already exists, and
  show them as cards for a person to confirm. A confirmed candidate becomes a
  Lean rule; a rejected one points at a possible bug. Sources:
  - traces from tests, logs and telemetry: likely invariants (Daikon-style)
    and inductive logic programming for relational rules;
  - issues and the PRs that resolved them, which hold intent: the before and
    after behaviour gives an example pair, the discussion gives the rule and
    its reason, and a "working as intended" close gives a pinned answer.
    Each candidate links to where it was decided, and the latest decision
    wins. Only the rule and the link are kept, never issue text that might
    hold personal data. This is an issue-tracker capture adapter.
  - An LLM can draft the model of actions from code, and replaying traces
    checks the draft.
- **What runs where.**
  - Lean holds the model, rules, proofs, checkers, cards, explanations, and
    the small engines (Datalog, goal-directed search, abduction) for models of
    Tribrach's first size.
  - External engines are optional suggesters behind the same checkers:
    Soufflé for large Datalog, SWI-Prolog, SAT/SMT solvers, ILP learners such
    as Popper, and invariant miners. Lean's own `bv_decide`, which checks an
    external SAT solver's certificate, is the precedent.
- **Next:** negation of derived predicates (stratification), engine
  completeness so that "no" is proved too, and goal-directed search for the
  to-do rule cards.
