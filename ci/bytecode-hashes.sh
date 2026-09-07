#!/usr/bin/env bash
# WP-116 — print sha256(creation bytecode) and sha256(deployed bytecode) per contract from the local build.
# Output is a Markdown table; deploy/BUILD.md §3 carries the arm64 result, CI prints the x86_64 one.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
forge build >/dev/null
echo "| Contract | sha256(creation) | sha256(deployed) | deployed bytes |"
echo "|---|---|---|---|"
for spec in \
  src/handle/HandleRegistry.sol:HandleRegistry \
  src/handle/HandleController.sol:HandleController \
  src/tld/TldRegistrarController.sol:TldRegistrarController \
  src/tld/TldRegistrar.sol:TldRegistrar \
  src/tld/TldDirectory.sol:TldDirectory \
  src/tld/TldMetadata.sol:TldMetadata \
  src/pricing/ArcNSPriceOracle.sol:ArcNSPriceOracle \
  src/resolver/ArcNSResolver.sol:ArcNSResolver \
  script/lib/EnsBootstrap.sol:EnsBootstrap \
  lib/ens-contracts/contracts/registry/ENSRegistry.sol:ENSRegistry \
  lib/ens-contracts/contracts/root/Root.sol:Root \
  lib/ens-contracts/contracts/reverseRegistrar/ReverseRegistrar.sol:ReverseRegistrar \
  lib/ens-contracts/contracts/universalResolver/UniversalResolver.sol:UniversalResolver \
  lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController; do
  name="${spec##*:}"
  c=$(forge inspect "$spec" bytecode | tr -d '\n' | sha256sum | awk '{print $1}')
  d=$(forge inspect "$spec" deployedBytecode | tr -d '\n')
  dh=$(printf '%s' "$d" | sha256sum | awk '{print $1}')
  bytes=$(( (${#d} - 2) / 2 ))
  echo "| $name | $c | $dh | $bytes |"
done
echo "BYTECODE_HASHES_OK"
