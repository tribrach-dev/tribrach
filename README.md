# Tribrach

**State your system's rules once, in Lean. Check that your code follows them.**

A *tribrach* is the mount between a surveyor's tripod and the instrument on top.
It holds one exact point over the ground, and lets you swap instruments
(theodolite, prism, GPS) without losing that point. Tribrach works the same
way: one proved model of your system is the fixed point, and *instruments* for
each language or domain check that real code matches it.

> Status: pre-alpha, private. Tribrach is an independent project. Apps adopt
> it as an ordinary dependency (a Lake package, a Go module, a Swift package);
> it never depends on, or contains code from, any app that uses it.

## What it promises (and what it doesn't)

- **The model is proved.** Rules and operations are written in Lean, and every
  operation is proved to keep the rules.
- **The link to your code is checked.** Instruments tie Lean definitions to
  host-code symbols, keep that code pure, catch drift with stamps, replay
  generated operation sequences against the real implementation, and emit
  runtime checkers.
- It does **not** claim your Go or Swift is proved correct. It claims your code
  agrees with a proved model on everything we can generate and check, and that
  you'll hear about it when either side changes.

## Layout

| Part | What it is | Where |
| --- | --- | --- |
| Core | Lean library for models, rules and links; exporters for manifests, test vectors and stamps; the `tribrach` runner | this repo |
| `tribrach-go` | Go instrument: `go vet` analyzer for links, purity, drift and stamps; vector replay | planned repo |
| `tribrach-swift` | Swift instrument: SwiftSyntax analyzer, SwiftPM build and command plugins; vector replay | planned repo |
| `tribrach-data` | Data pack: stored-data rules, operation replay against real stores, and migrations with data contracts (forward/rollback reads, repair on read, recovery plans, older writers), persisted-field diff, golden records, rollback challenge; adapters for SwiftData, Firestore, SQLite | planned repo |

Language instruments live in their own repos because Swift packages must sit at
a repo root and Lean's package index lists one package per repo.

Examples are in [examples/](examples), formats in [docs/formats](docs/formats)
and [schema/](schema), and conformance goldens in [tests/](tests).

See [docs/architecture.md](docs/architecture.md) for the design and
[docs/roadmap.md](docs/roadmap.md) for what ships when.

## Try the core

```sh
lake build
```

`examples/counter` shows the smallest model: a counter that never passes
`max`, with each operation proved and any sequence of operations proved for free
by `Tribrach.Model.run_preserves`.

## Licence

Apache-2.0, with no paid edition. See [LICENSE](LICENSE), [NOTICE](NOTICE),
[GOVERNANCE.md](GOVERNANCE.md) and [CONTRIBUTING.md](CONTRIBUTING.md)
(contributions are signed off under the DCO).
