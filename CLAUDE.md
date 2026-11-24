# Notes for Claude

- Tribrach is an independent open-source project. Applications use it as a
  dependency; it must never depend on, name, or contain code, data or models
  from any application (including the maintainers' own apps).
- Write code fresh against docs/architecture.md and neutral examples. Do not
  copy files from application repositories, even ones you can read.
- Changes that only matter to one application belong in that application.
- The repo stays private until the maintainers decide to publish.
- Lean toolchain is pinned in `lean-toolchain`; build with `lake build`.
  No `sorry`, no new `axiom`.
- Instruments go in separate repos: tribrach-go, tribrach-swift,
  tribrach-data.
- `examples/` holds self-contained projects CI builds (neutral only);
  `tests/` holds goldens and conformance cases (`python tools/check_captures.py`).
- Sign off every commit (DCO, no CLA). A sign-off is a human's legal statement:
  agents never sign off as themselves; they add Co-Authored-By, and the person
  who asked for the change signs off.
- CI may only use GitHub-made or verified-creator actions (org policy).
