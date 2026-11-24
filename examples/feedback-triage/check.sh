#!/usr/bin/env sh
# Run by CI after `lake build`: replay every report and compare its triage.
set -eu
lake exe triage reports.json
