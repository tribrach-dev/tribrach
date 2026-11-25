#!/usr/bin/env sh
# Run by CI after `lake build`: replay every report and compare its triage,
# then make sure the committed rule cards match the model.
set -eu
lake exe triage reports.json
lake exe cards --check RULES.md
