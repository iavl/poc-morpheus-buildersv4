#!/usr/bin/env sh
# ---------------------------------------------------------------------------
# A-002 PoC runner - BuildersV4 retroactive withdraw lock (Base mainnet fork).
#
#   ./run.sh                 run both tests against the pinned fork
#   ./run.sh -vvvv           any extra args are passed to `forge test`
#   BASE_RPC=<url> ./run.sh  use your own archive RPC
#
# Requirements: Foundry (forge, cast) - https://book.getfoundry.sh
# No private key, no funded account, no deploy: the test forks Base at block
# 52832790 and fabricates the victim's MOR balance with vm.store.
# ---------------------------------------------------------------------------
set -eu

cd "$(dirname "$0")"

FORGE_BLOCK="52832790"

if ! command -v forge >/dev/null 2>&1; then
    echo "error: forge not found. Install Foundry first:" >&2
    echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
    exit 1
fi

# Pick a public Base RPC that answers before handing it to the fork cheatcode.
if [ -z "${BASE_RPC:-}" ]; then
    for url in https://mainnet.base.org https://base.drpc.org https://base.llamarpc.com; do
        if command -v cast >/dev/null 2>&1 && cast chain-id --rpc-url "$url" >/dev/null 2>&1; then
            BASE_RPC="$url"
            break
        fi
    done
fi
export BASE_RPC="${BASE_RPC:-https://mainnet.base.org}"

echo "forge    : $(forge --version | head -n 1)"
echo "solidity : $(grep -E '^solc_version' foundry.toml | cut -d'"' -f2)"
echo "fork     : Base mainnet @ block $FORGE_BLOCK"
echo "rpc      : $BASE_RPC"
echo "---------------------------------------------------------------------------"

exec forge test -vv "$@"
