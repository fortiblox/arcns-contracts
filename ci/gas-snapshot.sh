#!/usr/bin/env bash
# WP-117 — gas snapshot (write) / check. Fork tests excluded (gas is 0 when skipped), fuzz/invariant excluded
# (μ/~ depend on the seed). `--check` fails CI when any pinned test regresses by more than 5 %.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
mode="${1:-write}"
args=(--no-match-path 'test/fork/*' --no-match-test 'testFuzz_|invariant_')
if [ "$mode" = "check" ]; then
  forge snapshot --check --tolerance 5 "${args[@]}" && echo "GAS_SNAPSHOT_OK" || { echo "GAS_SNAPSHOT_FAILED"; exit 1; }
else
  forge snapshot "${args[@]}" && echo "GAS_SNAPSHOT_WRITTEN"
fi
