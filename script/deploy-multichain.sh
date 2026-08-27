#!/bin/bash
set -e

# Multi-chain CREATE2 deployment for ERC8183.
# Constructor args are (platformFeeBp, evaluatorFeeBp, treasury, owner).
# Per-chain payment tokens are allowlisted post-deploy, not baked into CREATE2.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ERC8183 Multi-Chain Deployment${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

export TREASURY="${TREASURY:?TREASURY env var required}"
export PLATFORM_FEE_BP="${PLATFORM_FEE_BP:-250}"
export EVALUATOR_FEE_BP="${EVALUATOR_FEE_BP:-100}"
export OWNER="${OWNER:-$TREASURY}"
export SALT="${SALT:-0x0000000000000000000000000000000000000000000000000000000000000001}"

# Format: CHAIN_NAME|RPC_URL|PAYMENT_TOKEN|ETHERSCAN_API_KEY
declare -a CHAINS=(
    # Uncomment and configure the chains you want to deploy to:
    # "ethereum|$ETHEREUM_RPC_URL|0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48|$ETHERSCAN_API_KEY"
    # "base|$BASE_RPC_URL|0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913|$BASESCAN_API_KEY"
    # "arbitrum|$ARBITRUM_RPC_URL|0xaf88d065e77c8cC2239327C5EDb3A432268e5831|$ARBISCAN_API_KEY"
    # "optimism|$OPTIMISM_RPC_URL|0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85|$OPTIMISM_API_KEY"
    # "polygon|$POLYGON_RPC_URL|0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359|$POLYGONSCAN_API_KEY"
)

if [ ${#CHAINS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No chains configured. Edit this script to add chain configurations.${NC}"
    echo ""
    echo "Example configuration:"
    echo '  "ethereum|https://eth-mainnet.g.alchemy.com/v2/xxx|0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48|YOUR_ETHERSCAN_KEY"'
    exit 1
fi

DEPLOYED=()
FAILED=()

for chain_config in "${CHAINS[@]}"; do
    IFS='|' read -r CHAIN_NAME RPC_URL PAYMENT_TOKEN EXPLORER_API_KEY <<< "$chain_config"

    echo ""
    echo -e "${YELLOW}Deploying to ${CHAIN_NAME}...${NC}"
    echo "  RPC: ${RPC_URL:0:50}..."
    echo "  Payment Token (post-deploy allowlist): $PAYMENT_TOKEN"

    export PAYMENT_TOKEN

    if forge script script/DeployMultiChain.s.sol:DeployMultiChain \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --verify \
        --etherscan-api-key "$EXPLORER_API_KEY" \
        2>&1; then
        echo -e "${GREEN}✓ ${CHAIN_NAME} deployment successful${NC}"
        DEPLOYED+=("$CHAIN_NAME")
    else
        echo -e "${RED}✗ ${CHAIN_NAME} deployment failed${NC}"
        FAILED+=("$CHAIN_NAME")
    fi
done

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Deployment Summary${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ ${#DEPLOYED[@]} -gt 0 ]; then
    echo -e "${GREEN}Successful (${#DEPLOYED[@]}):${NC}"
    for chain in "${DEPLOYED[@]}"; do
        echo -e "  ${GREEN}✓${NC} $chain"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed (${#FAILED[@]}):${NC}"
    for chain in "${FAILED[@]}"; do
        echo -e "  ${RED}✗${NC} $chain"
    done
    exit 1
fi

echo ""
echo -e "${GREEN}All deployments completed successfully!${NC}"
