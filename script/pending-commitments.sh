#!/usr/bin/env bash
# WP #7772 — pre-execute gate: "are there any V1 commitments currently pending on this namespace?"
# (CEO decision Q1, 2026-09-12: no app-side commitment-migration code; instead gate the cutover's
# `execute` step on a LIVE check that zero V1 commitments are pending, and either wait for them to
# clear naturally — reveal or expire, both happen inside the existing `maxCommitmentAge` ceiling — or
# report how long until they clear.)
#
# Why this is bash+cast, not a forge script: `HandleController`/`TldRegistrarController`'s
# `commitments` mapping has NO on-chain enumeration (checked: no `commitmentCount()`/iterator anywhere
# in src/handle/HandleController.sol or src/tld/TldRegistrarController.sol). The only way to find
# CANDIDATE commitment hashes is to scan `CommitmentMade(bytes32 indexed commitment, uint256 timestamp)`
# events, and both public Arc RPCs cap `eth_getLogs` at 10,000 blocks per call (script/DeployMarket.s.sol's
# own note) — event paging is exactly what the app/indexer already do off-chain; `cast logs
# --query-size` does the chunking (and retries 429s) for us, so this script just picks a safe block
# floor and lets it run. The final verdict per candidate (pending or not) is a plain live `cast call` of
# the SAME `commitments(bytes32)` getter `_consumeCommitment` itself reads — the single source of
# truth — checked against the exact age window `VerifyControllerV2.commitmentIsPending` (Solidity,
# unit-tested in `test/controller-v2/ControllerV2Cutover.t.sol`) uses, so this script's bash arithmetic
# is proven consistent with the contracts' own revert conditions, not trusted on its own.
#
#   ./script/pending-commitments.sh <CONTROLLER_V1_ADDR> <MAX_COMMITMENT_AGE_SECS> [RPC_URL] [FROM_BLOCK_FLOOR]
#
# FROM_BLOCK_FLOOR defaults to `now_block - MAX_COMMITMENT_AGE_SECS * BLOCKS_PER_SEC_UPPER_BOUND`
# (BLOCKS_PER_SEC_UPPER_BOUND=3, safely above the ~2.1 blocks/s observed live 2026-09-12 — override via
# env if Arc block time changes materially) so a 24h `maxCommitmentAge` scans back ~260k blocks by
# default; pass an explicit floor (e.g. the controller's own deploy block) to scan less.
#
# Prints one "PENDING <hash> age=<secs>" or "clear <hash> ..." line per candidate commitment found in
# the scan window, then exactly one of:
#   PENDING_COMMITMENTS_CLEAR 0
#   PENDING_COMMITMENTS_BLOCKING <n>
# Exit code 0 either way (this is a REPORT, not an enforcement gate — the runbook operator reads the
# marker and decides to wait or proceed); non-zero exit means "could not determine the answer" (RPC
# unreachable, decode failure) — treat that as BLOCKING, never as CLEAR.
set -u

CONTROLLER="${1:?usage: pending-commitments.sh <controller> <maxCommitmentAge> [rpcUrl] [fromBlockFloor]}"
MAX_AGE="${2:?maxCommitmentAge (seconds) required}"
RPC="${3:-${ARC_RPC_URL:-https://rpc.testnet.arc.io}}"
BLOCKS_PER_SEC_UPPER_BOUND="${BLOCKS_PER_SEC_UPPER_BOUND:-3}"

die() { echo "PENDING_COMMITMENTS_ERROR: $*" >&2; exit 1; }

command -v cast >/dev/null 2>&1 || die "cast not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH (used to decode log JSON)"

NOW_BLOCK="$(cast block-number --rpc-url "$RPC")" || die "eth_blockNumber unreachable"
NOW_TS="$(cast block "$NOW_BLOCK" --rpc-url "$RPC" --field timestamp)" || die "eth_getBlockByNumber unreachable"

DEFAULT_FLOOR=$((NOW_BLOCK - MAX_AGE * BLOCKS_PER_SEC_UPPER_BOUND))
[ "$DEFAULT_FLOOR" -lt 0 ] && DEFAULT_FLOOR=0
FROM_FLOOR="${4:-$DEFAULT_FLOOR}"
[ "$FROM_FLOOR" -lt 0 ] && FROM_FLOOR=0

echo "PENDING_COMMITMENTS_SCAN controller=$CONTROLLER now_block=$NOW_BLOCK now_ts=$NOW_TS max_age=$MAX_AGE from_block=$FROM_FLOOR"

logs_json="$(cast logs --address "$CONTROLLER" --from-block "$FROM_FLOOR" --to-block "$NOW_BLOCK" \
  --query-size 9000 --json 'CommitmentMade(bytes32,uint256)' --rpc-url "$RPC" 2>&1)" \
  || die "eth_getLogs [$FROM_FLOOR,$NOW_BLOCK] failed: $logs_json"

case "$logs_json" in
  \[*) ;;  # looks like a JSON array, proceed
  *) die "unexpected cast logs output (not a JSON array): $logs_json" ;;
esac

mapfile -t CANDIDATES < <(python3 - "$logs_json" <<'PYEOF'
import json, sys
rows = json.loads(sys.argv[1])
seen = set()
for r in rows:
    commitment = r["topics"][1]
    if commitment in seen:
        continue
    seen.add(commitment)
    print(commitment)
PYEOF
)

echo "PENDING_COMMITMENTS_CANDIDATES ${#CANDIDATES[@]}"

pending_count=0
for commitment in "${CANDIDATES[@]:-}"; do
  [ -z "$commitment" ] && continue
  ts_raw="$(cast call "$CONTROLLER" 'commitments(bytes32)(uint256)' "$commitment" --rpc-url "$RPC")" \
    || die "commitments($commitment) call failed"
  ts="${ts_raw%% *}"   # strip cast's "[n]" human-readable suffix on large integers, keep the leading digits
  if [ "$ts" = "0" ]; then
    echo "  clear    $commitment revealed-or-never-live"
    continue
  fi
  age=$((NOW_TS - ts))
  if [ "$age" -lt "$MAX_AGE" ]; then
    echo "  PENDING  $commitment age=${age}s (max ${MAX_AGE}s)"
    pending_count=$((pending_count + 1))
  else
    echo "  clear    $commitment age=${age}s >= max ${MAX_AGE}s (expired, permanently unrevealable regardless of cutover)"
  fi
done

if [ "$pending_count" -eq 0 ]; then
  echo "PENDING_COMMITMENTS_CLEAR 0"
else
  echo "PENDING_COMMITMENTS_BLOCKING $pending_count"
fi
