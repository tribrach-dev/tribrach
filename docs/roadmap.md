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
  hand-written schema in `schema/` becomes generated.
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
