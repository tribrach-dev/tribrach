#!/usr/bin/env sh
# Run by CI after `lake build`: answer every question, re-check every why tree.
set -eu
lake exe why
