#!/usr/bin/env sh
# Run by CI after `lake build`.
set -eu
lake exe impact
