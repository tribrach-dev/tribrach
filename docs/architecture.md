# Architecture

## Three layers

1. **Core (language-neutral, Lean).**
   - `Tribrach.Model`: state, invariant, operations, and the preservation
     property (`Model.Preserves`, `Model.run_preserves`).
   - `Tribrach.Link`: links from Lean definitions to host symbols, with stamps.
   - Exporters (planned): a manifest of links and stamps, test vectors
     (operation sequences with expected results) as JSON, and claim files.
   - Runner (planned): `tribrach check` runs every instrument and the
     compatibility matrix.

2. **Instruments (one per language).** Each does the same five jobs:
   1. *Link*: read `//tribrach:link <LeanName>` annotations and match them to
      the manifest.
   2. *Purity*: keep linked code in the pure subset (no I/O, clocks, globals).
   3. *Drift*: compare stamps so a change on either side fails the build.
   4. *Replay*: run exported vectors against the host implementation.
   5. *Checkers*: emit runtime invariant checks for use at launch, after
      migrations, or in tests.

3. **Packs (one per domain).** Built on instruments. The first is
   `tribrach-data` (see the roadmap for its full scope); its migration part has versioned data contracts with `forwardRead`,
   `rollbackRead`/`rollbackWrite`, `repairOnRead`, `recoveryPlan` and
   `olderWriter`, a persisted-field diff, golden records per version, and a
   rollback challenge, with small adapters per store (SwiftData, Firestore,
   SQLite). Later packs could cover UI state machines and sync merge rules.

## Package contract

Tribrach is split into four kinds of package. Each owns one set of
responsibilities, and packages only talk to each other through the core
formats.

| Kind | Owns | Must never |
| --- | --- | --- |
| **Core** (`tribrach`) | Model and link library; the formats (manifest, vectors, stamps, captures, claims, diagnostics); the rules-file generator; the `check`, `explain` and `guard` runner; the conformance suite | Know about any language or store |
| **Instrument**, one per language (`tribrach-go`, `tribrach-swift`) | Static analysis for that language (links, purity, drift, stamps, telemetry awareness and suggestions, code-shape guardrails) and its runtime (generated checkers, replay harness, telemetry hooks) | Define rules or formats of its own |
| **Pack**, one per domain (`tribrach-data`) | Domain rule shapes for the rules file, domain guardrails and its own diagnostics | Talk to a specific store directly |
| **Adapter** | Exactly one connection: a store (SwiftData, Firestore, SQLite), a capture source (GitHub pull requests, an editor) or a telemetry sink (OpenTelemetry) | Make decisions; it only translates to and from the core formats |

### Package descriptor

Every package declares what it provides in `tribrach-package.toml`:

```toml
name = "tribrach-swift"
kind = "instrument"            # core | instrument | pack | adapter
formats = { manifest = "1", vectors = "1", diagnostics = "1" }
provides = ["link", "purity", "drift", "replay", "checker", "telemetry", "guard:code-shape"]
owns-links = ["tribrach.swift"] # instrument ids whose links this package checks
diagnostics = "TRS"            # diagnostic code prefix, e.g. TRS0101
```

Descriptors use a subset of TOML: top-level `key = value` lines whose values
are strings, arrays of strings or inline tables, plus `#` comments.

### Link ownership

Every link names its owner by an **instrument id**: dot-separated, lowercase
segments that start with the publisher, such as `tribrach.go`,
`tribrach.swift` or `acme.kotlin`. Core never lists owners. Installed
packages register the ids they own under `owns-links`, and the runner
resolves each link to the package that registered its id
(`Tribrach.Package`). A third-party instrument therefore needs no change to
core; `examples/third-party-instrument` shows one.

- **Existing names.** The first manifests used a closed list: `go`, `swift`,
  `migration`. They still read and map to `tribrach.go`, `tribrach.swift` and
  `tribrach.data.migration`, with a note suggesting the id instead.
- **Migrations.** A migration written in Swift or Go is host code, so its
  links belong to that language's instrument. `tribrach.data.migration` is
  for migration files that aren't host code (for example SQL). The
  `tribrach-data` package registers it, and an adapter for the store reads
  the files, which keeps the pack free of store details.
- **Diagnostics.**
  - `TR0101`: no installed package owns an id.
  - `TR0102`: two packages register the same id.
  - `TR0103`: a descriptor is malformed or names an invalid id.

  Each says which package or link is involved and what to do about it.

- Diagnostic prefixes keep codes from colliding: `TR` core, `TRG` Go,
  `TRS` Swift, `TRD` data. Adapters use their pack's or instrument's prefix.
- `tribrach check` reads the descriptors and reports gaps, for example links
  in Swift with no Swift instrument installed, or the data pack without an
  adapter for the store in use.
- Each package runs the core conformance suite for every format version it
  declares.

### Where new work goes

- A new language is an instrument.
- A new store, capture source or telemetry sink is an adapter.
- A new kind of rule or guardrail is a pack (or an addition to one).
- The core changes only when a format changes, which needs an issue first
  (see GOVERNANCE.md).

## Shared formats

`Tribrach.Export` writes the files instruments read; instruments never read
Lean. Example: `examples/export-formats`. Instruments prove they read the
formats the same way by passing `tests/conformance` (see its README);
`tools/conformance.py` is the reference implementation.

- **Manifest** (`tribrach.manifest.v1`, `schema/manifest.schema.json`): one
  entry per link with the Lean name, owner id, host symbol and stamp. Built
  with `lean% Name`, which gives the name and its stamp.
- **Stamps:** `stamp% Name` hashes the definition and every project
  constant it uses, followed across files, as 16 hex digits. The toolchain,
  Tribrach and common libraries are referred to by name only. So a change
  anywhere upstream in the project moves the stamps of everything
  downstream. Stamps are stable for one toolchain, so a toolchain bump
  re-stamps on purpose. On the host side the stamp sits next to the symbol it
  covers (`//tribrach:stamp`), never in a shared file, so stamping one target
  can't disturb another.
- **Vectors** (`tribrach.vectors.v1`, `schema/vectors.schema.json`): cases
  with a start state, operations as `{"op": name, ...}` objects, and the state
  after every step. `Model.trace` produces them and `Model.trace_preserves`
  proves every expected state keeps the model's rules.
- **Annotations:** `//tribrach:link <LeanName>`, `//tribrach:pure`,
  `//tribrach:stamp <hex>`; one grammar for every language with `//` line
  comments, and no space after the `//`, like `//go:` directives.
- **Export on build:** `#tribrach_export bundle` writes the files while Lean
  compiles the module holding it. Lake recompiles that module whenever
  anything it imports changes, so `lake build` keeps the exported files
  current. CI re-exports and fails if the committed files differ.
- **Graph** (`tribrach.graph.v1`, committed): every project constant behind
  the links, with its own hash and what it uses. It is the invalidation
  graph from Lean definitions to links to host symbols.
- **Refresh** (`tribrach.refresh.v1`, a build output): what changed since
  the committed graph and manifest. For each instrument it lists the links
  to re-check, with the upstream definitions that caused it, for people and
  CI comments. Instruments report the drift themselves; the refresh report
  explains it in one place.
- **Schemas** (`Tribrach.Schema`): a JSON document type described once in
  Lean, as a shape (`Ty`: booleans, bounded integers, strings with lengths
  and patterns, constants, enums, arrays, closed objects) plus rules the
  shape can't say. From it come a JSON Schema (draft 2020-12) for other tools
  and a checker in Lean (`Schema.accepts`). Rules appear in the schema under
  `x-tribrach` by Lean name and stamp. String patterns come from a closed
  list (`Pat`). Each is a pattern tree (`Tribrach.Re`: literals, character
  sets, sequences, choices, repeats, and `without` for the two refusals
  `relPath` needs); the schema's regex and the Lean checker are both read off
  the tree. `tests/conformance/patterns.json` carries the trees, so an
  instrument runs one generic matcher instead of a checker per pattern, and
  an adapter can render a pattern in its own dialect (a database `CHECK`, say)
  instead of trusting a regex dialect. A fuzz run keeps Lean, the reference
  tree matcher and the regexes in step.
  `#tribrach_write files` writes the schema on build, like
  `#tribrach_export`. `schema/capture.schema.json` is generated this way
  (example: `examples/capture-schema`); the other schemas are still written
  by hand.
- **Wire codecs** (`Tribrach.Wire`): a `Codec` puts a message's schema
  shape, writer and reader side by side, built field by field (`Obj`) and
  case by case (`Codec.tagged`), so a message is described once. Every
  decoder checks the shape before reading, so it accepts what the schema
  accepts. The wire mapping lives here, not in the model: money and 64-bit
  ids as decimal strings (`Ty.decimal`, bounds under `x-tribrach`), RFC 3339
  instants read at any offset and written in UTC, and optional fields left
  out rather than `null`. Example: `examples/dto-parking`.
  `tests/conformance/wire.json`, written by `tools/WireCases.lean` from the
  codecs themselves, pins how each primitive reads JSON text and writes it
  back, so instruments' readers can be checked one primitive at a time.
- **Exchanges** (`tribrach.exchanges.v1`, `schema/exchanges.schema.json`):
  requests a service handled, what it was given besides the request (clock,
  ids, stubbed answers), the calls it made with their answers, and the
  status and response. Hosts replay them against their handlers.
- **Claims** (planned next): which properties are proved, which are tested,
  and by what.

Value conventions for states and operations, so every host reads them the
same way:

- Prefer integers in fixed units (per-mille, basis points, microdegrees) to
  floats.
- Integers beyond ±2^53 (hashes, 64-bit ids) are written as decimal strings.
- Enumerations are strings naming the case; absent optionals are `null`.
- Lists are written in the model's order. If the host's order differs, the
  model should define a canonical order and the codec should sort by it.
- `Nat` subtraction truncates at zero; a host using signed integers must
  match that explicitly.

## Contract identity and dependencies

Links point at Lean names and carry stamps, which show that something changed
but not what else needs review. `Tribrach.Contract` adds the missing pieces
(example: `examples/contract-impact`):

- **Stable ids.** Each contract has a `ContractId` (`shipping.orders`) that
  survives renaming the Lean definition. A **revision** counts accepted
  changes in meaning; the stamp still catches every change.
- **Typed edges.**
  - `dependsOn` means the downstream contract uses the upstream's
    guarantees, so those uses must be re-checked.
  - `refines` means everything the downstream allows, the upstream allows,
    so the refinement must be re-established.

  Each edge records the upstream revision it was established against. Edges
  must form a DAG. The checks are `TR0201` (missing contract), `TR0202`
  (cycle) and `TR0203` (reliance on a revision that doesn't exist yet).
- **Revision records.** Each accepted revision records what kind of change
  it was and how well that is known:
  - *Kind:* `refine`, `extend` with a direction (`backward`, `forward` or
    `both`), `breaking` or `deprecate`. A record with no kind is
    unclassified. A rename keeps the id and needs no revision.
  - *Evidence, weakest first:* `refuted`, `structural`, `declared`,
    `tested`, `checked`.
  - *Optional:* a migration reference, and the stamp the record was made
    against. A stale record (`TR0205`) is ignored.

  A refutation beats any claim about the same revision (`TR0204`). Over a
  range of revisions, the weakest step decides.
- **Proved or derived impact.** `Tribrach.Impact` turns the records and
  edges into facts for the logic layer and derives one verdict per
  dependent, with a why tree that `Why.check` re-verifies.
  - A **proved** verdict comes from a rule backed by a theorem. Today that is
    `Model.carry_over`: a checked refinement keeps every guarantee a
    `dependsOn` dependent used, and the example states it as a corollary
    per edge.
  - Every other rule is **policy** and can only ask for more work: review,
    confirm a claim, re-prove, or move off a deprecated revision.
  - A clearing rule without a theorem is reported (`TR0206`).
    `cleared_only_by_backed` proves that, otherwise, a checked proved
    verdict always comes from a backed rule.
  - Where proof and policy meet on one edge, the proof decides and the
    disagreement is reported (`TR0207`).

**Effect on formats.** This is a format change, so it ships as new major
versions.

- *Manifest v2:* each entry gains `contract` (the id) and `revision`. Links
  refer to the contract id; the Lean name stays as information. A v1
  manifest is read by using the Lean name as the id, with a warning
  suggesting a real id.
- *Claims v2:* a claim records `id@revision` for the contract it is about
  and for each dependency it relied on, so a claim made against an older
  revision is visibly stale.
- *Revision records* (the `history` of the graph) are a new file next to the
  manifest, one entry per accepted revision, with its compatibility and
  evidence.

## Feedback triage

`Tribrach.Triage` replays a user's feedback report against a model and sorts
it into one of six verdicts: `malformed`, `version-mismatch`, `model-gap`,
`code-bug`, `expectation-mismatch` or `cannot-reproduce`.

A project supplies a `Subject` for its `Model`:

- the model version;
- how states and operations are read from and written to JSON;
- an executable rule check, `broken`, with a proof (`sound`) that a state it
  passes keeps the model's invariant.

The report format, the replay, the gap detection and a ready-made `main`
(`Triage.runFile`) are shared. Gaps are found without project code:

- an operation the subject doesn't decode is a gap;
- so is any state key that doesn't survive reading and writing back, named
  by path (`observed[0].pinned`).

Example: `examples/feedback-triage`.

**Plumbing to feedback services.** The core only speaks two JSON formats:

- `tribrach.report.v1`, the report envelope (`schema/report.schema.json`). It
  says where the report came from (service, ticket id), the app version, the
  model version and stamp, and the privacy labels the user saw.
- `tribrach.triage.v1`, one result per report from `triage --json`
  (`schema/triage.schema.json`). It gives the verdict, reason and evidence,
  the source passed through, and a `group` key shared by duplicate reports.

Adapters for particular services, and the routing of verdicts to issue
trackers, product boards and replies, live outside the core. A routing file
names the environment variable for each token, never the token itself.
`examples/feedback-sources` shows offline stubs; live connectors belong in a
separate repository, like the instruments.

## Build plan

Tribrach is written fresh against this design and its own neutral examples.
It does not copy code from any application, and nothing here depends on one.
Applications adopt released versions and migrate their own annotations to the
`//tribrach:` syntax as their own work.

1. Core formats and exporters: manifest, vectors and stamps (done), claims.
2. `tribrach-go`: `go vet` analyzer and vector replay.
3. `tribrach-swift`: SwiftSyntax analyzer, SwiftPM plugins and vector replay.
4. `tribrach-data`: data contracts and adapters, demonstrated on a neutral
   example (a to-do app with three schema versions).
