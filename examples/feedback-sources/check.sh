#!/usr/bin/env sh
# Run by CI after `lake build`: pull the fixtures, triage, route, and compare
# everything with expected/. On a difference, print what was produced.
set -eu
rm -rf out
python3 feedback.py pull --offline
lake exe triage --json out/reports.json > out/triage.jsonl
python3 feedback.py route
if ! diff -ru expected out; then
  echo "----- produced files -----"
  find out -type f | sort | while read -r f; do
    echo "===== ${f#out/}"
    cat "$f"
  done
  exit 1
fi
echo "ok: pulled, triaged and routed as expected"
