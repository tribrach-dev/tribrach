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
diagnostics = "TRS"            # diagnostic code prefix, e.g. TRS0101
```

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

## Shared formats (to stabilise first)

- Manifest: links, Lean names, host symbols, stamps, format version.
- Vectors: JSON operation sequences with expected states and outputs.
- Claims: which properties are proved, which are tested, and by what.
- Annotation syntax: `//tribrach:link`, `//tribrach:pure`, `//tribrach:stamp`.

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
- **Compatibility, weakest first.**
  - `structural`: changed, nothing more is known.
  - `declared`: an author says it is compatible; not verified.
  - `checked`: backed by named evidence, such as a theorem or a vector suite
    run in CI.

  Over a range of revisions, the weakest step decides. The impact report
  lists direct dependents with that verdict, and lists their own dependents
  as possibly affected when the direct one needs review.

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

## Build plan

Tribrach is written fresh against this design and its own neutral examples.
It does not copy code from any application, and nothing here depends on one.
Applications adopt released versions and migrate their own annotations to the
`//tribrach:` syntax as their own work.

1. Core formats and exporters (manifest, vectors, stamps, claims).
2. `tribrach-go`: `go vet` analyzer and vector replay.
3. `tribrach-swift`: SwiftSyntax analyzer, SwiftPM plugins and vector replay.
4. `tribrach-data`: data contracts and adapters, demonstrated on a neutral
   example (a to-do app with three schema versions).
