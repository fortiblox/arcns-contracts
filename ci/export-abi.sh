#!/usr/bin/env bash
# Export the stable ABIs the SDK lane consumes (contracts/abi/*.json) with `forge inspect`. Run after any
# interface change; CI (contracts.yml) re-runs it and fails on `git diff --exit-code contracts/abi`.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
mkdir -p abi
forge build >/dev/null
for spec in \
  src/handle/HandleRegistry.sol:HandleRegistry \
  src/handle/HandleController.sol:HandleController \
  src/tld/TldRegistrarController.sol:TldRegistrarController \
  src/tld/TldRegistrar.sol:TldRegistrar \
  src/tld/TldDirectory.sol:TldDirectory \
  src/tld/TldMetadata.sol:TldMetadata \
  src/pricing/ArcNSPriceOracle.sol:ArcNSPriceOracle \
  src/resolver/ArcNSResolver.sol:ArcNSResolver \
  src/market/ArcNSMarket.sol:ArcNSMarket \
  lib/ens-contracts/contracts/registry/ENSRegistry.sol:ENSRegistry \
  lib/ens-contracts/contracts/root/Root.sol:Root \
  lib/ens-contracts/contracts/reverseRegistrar/ReverseRegistrar.sol:ReverseRegistrar \
  lib/ens-contracts/contracts/universalResolver/UniversalResolver.sol:UniversalResolver \
  lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController; do
  name="${spec##*:}"
  forge inspect "$spec" abi --json > "abi/$name.json"
done
echo "ABI_EXPORTED $(ls abi | wc -l) files"
