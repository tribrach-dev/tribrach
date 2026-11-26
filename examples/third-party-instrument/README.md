# Third-party instrument

Shows that a package outside Tribrach can own links without any change to
core. Each package lists the instrument ids it owns in its
`tribrach-package.toml`:

```toml
name = "acme-kotlin"
kind = "instrument"
owns-links = ["acme.kotlin"]
```

and a link names its owner by that id. `lake exe owners packages/*/tribrach-package.toml`
resolves every link in a small manifest and prints, for this fixture:

- `acme.kotlin` links are owned by `acme-kotlin`, which core has never heard of;
- `tribrach.go` links, and the legacy owner name `go`, are owned by `tribrach-go`
  (a note suggests writing the id instead of the legacy name);
- `TR0103` for `packages/broken`, whose id `Kotlin` isn't valid;
- `TR0102` because `acme-kotlin-fork` registers `acme.kotlin` too;
- `TR0101` for a Swift link, because no installed package owns `tribrach.swift`.

The check fails if ownership or the diagnostics change.
