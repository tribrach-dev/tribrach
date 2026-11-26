#!/usr/bin/env sh
# Run by CI after `lake build`: list allowed outcomes and replay vectors.
set -eu
lake exe replay
