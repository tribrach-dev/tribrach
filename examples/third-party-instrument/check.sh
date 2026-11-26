#!/usr/bin/env sh
# Run by CI after `lake build`. Descriptors are passed in a fixed order so the
# expected diagnostics are stable.
set -eu
lake exe owners \
  packages/tribrach-go/tribrach-package.toml \
  packages/acme-kotlin/tribrach-package.toml \
  packages/acme-kotlin-fork/tribrach-package.toml \
  packages/broken/tribrach-package.toml
