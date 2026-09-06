#!/usr/bin/env bash
# WP-104 — Arc native-coin semantics that a forge fork CANNOT reproduce (revm runs a standard EVM;
# docs.arc.io/arc/references/evm-differences). Asserted through the real node with `cast`.
# A failing `vm.rpc` cheatcode cannot be caught by try/catch or satisfied by expectRevert in
# forge 1.8.1, so the negative path lives here. Run by the CI fork job next to `forge test`.
#
#   ARC_RPC_URL=https://rpc.testnet.arc.io test/fork/arc-native-semantics.sh
#
# Prints exactly one of: ARC_NATIVE_SEMANTICS_VERIFIED / ARC_NATIVE_SEMANTICS_FAILED (exit 1).
set -u

RPC="${ARC_RPC_URL:?required}"
ZERO=0x0000000000000000000000000000000000000000
# Any existing account works as `from`; estimateGas on Arc checks the zero-address rule before balance.
FROM=0x41675C099F32341bf84BFc5382aF534df5C7461a   # Safe 1.4.1 singleton (has code on Arc testnet)
EXPECT_REVERT="Zero address not allowed"

fail() { echo "ARC_NATIVE_SEMANTICS_FAILED: $*"; exit 1; }

command -v cast >/dev/null 2>&1 || fail "cast not on PATH"

chain_id="$(cast chain-id --rpc-url "$RPC")" || fail "eth_chainId unreachable"
[ "$chain_id" = "5042002" ] || fail "chain id $chain_id != 5042002"

# 1) value-bearing transfer to the zero address is refused by the node
out="$(cast estimate --from "$FROM" --value 1 "$ZERO" --rpc-url "$RPC" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "1 wei to 0x0 was accepted (estimate=$out)"
case "$out" in
  *"$EXPECT_REVERT"*) ;;
  *) fail "1 wei to 0x0 failed for another reason: $out" ;;
esac

# 2) zero-value call to the zero address is a plain 21000-gas transaction
gas="$(cast estimate --from "$FROM" --value 0 "$ZERO" --rpc-url "$RPC" 2>&1)" || fail "0 wei to 0x0 failed: $gas"
[ "$gas" = "21000" ] || fail "0 wei to 0x0 estimated $gas != 21000"

echo "ARC_NATIVE_SEMANTICS_VERIFIED chain=$chain_id zero_value_gas=$gas revert='$EXPECT_REVERT'"
