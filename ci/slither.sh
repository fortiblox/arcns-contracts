#!/usr/bin/env bash
# WP-117 — static analysis gate. Runs slither (pinned 0.11.3) over contracts/src only (verbatim libs carry
# their upstream audits) and fails on any High/Medium finding that is not triaged in contracts/SECURITY-NOTES.md.
# Prints exactly one final marker: SLITHER_CLEAN or SLITHER_FAILED (Operating Agreement §3 — never infer
# success from piped output). Usage: contracts/ci/slither.sh [slither-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
SLITHER="${1:-${SLITHER_BIN:-slither}}"
if ! command -v "$SLITHER" >/dev/null 2>&1; then
  echo "slither binary not found ($SLITHER); install: python3 -m venv .venv && .venv/bin/pip install slither-analyzer==0.11.3"
  echo "SLITHER_FAILED"; exit 2
fi
export PATH="$HOME/.foundry/bin:$PATH"
out="$(mktemp)"
set +e
"$SLITHER" . --config-file slither.config.json --triage-database slither.db.json --json "$out.json" >"$out" 2>&1
rc=$?
set -e
# slither exits non-zero when findings at/above fail_on exist (or on a crash). Show the summary either way.
grep -E "^INFO:Detectors|^Reference|^INFO:Slither|Error" "$out" | head -80 || true
if [ $rc -eq 0 ]; then
  python3 - "$out.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
res=d.get("results",{}).get("detectors",[])
from collections import Counter
c=Counter((r["impact"],r["confidence"]) for r in res)
print("slither findings by (impact, confidence):", dict(c))
PY
  echo "SLITHER_CLEAN"; exit 0
fi
echo "slither exit code $rc — untriaged High/Medium findings or compile failure; see $out"
echo "SLITHER_FAILED"; exit 1
