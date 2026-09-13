# Deployment Guide

Deployment guide for the non-upgradeable ERC-8183 kernel.

## Prerequisites

| Tool | Version | Purpose |
| ---- | ------- | ------- |
| [Foundry](https://book.getfoundry.sh/) | ≥ 0.3.0 | Build, test, deploy |
| Solidity | 0.8.34 (`pragma ^0.8.28`) | Compiler |
| EVM target | Cancun | EIP-1153 transient storage (`TSTORE`/`TLOAD`) |

`foundry.toml` sets `evm_version = "cancun"`, `optimizer_runs = 200`, `via_ir = false`. Do not flip `via_ir`.

### Verify Installation

```bash
forge --version
forge build
forge test -vv
```

---

## Environment Setup

```bash
# .env
PRIVATE_KEY=0x...
RPC_URL=https://...
ETHERSCAN_API_KEY=...

TREASURY=0x...
PLATFORM_FEE_BP=250
EVALUATOR_FEE_BP=100
OWNER=0x...
PAYMENT_TOKEN=0x...   # optional; allowlisted after deploy
```

```bash
source .env
```

`.env` is in `.gitignore`.

---

## Constructor Parameters

| Parameter | Type | Required | Description |
| --------- | ---- | -------- | ----------- |
| `platformFeeBp_` | `uint256` | Yes | Platform fee in basis points |
| `evaluatorFeeBp_` | `uint256` | Yes | Evaluator fee in basis points |
| `treasury_` | `address` | Yes | Recipient of platform fees |
| `owner_` | `address` | Yes | Ownable2Step owner |

There is **no** `paymentToken_` constructor argument. Per-chain tokens are `setPaymentTokenAllowed` after deploy. A chain is unusable for paid jobs until at least one token is allowlisted.

| Constraint | Rule | Error |
| ---------- | ---- | ----- |
| `treasury_` | `!= address(0)` | `ZeroAddress()` |
| `platformFeeBp_ + evaluatorFeeBp_` | `≤ 5000` | `FeeTooHigh()` |

### Immutable after deploy

| Constant | Value |
| -------- | ----- |
| `MAX_FEE_BP` | `5000` |
| `BP_DENOMINATOR` | `10_000` |
| `HOOK_GAS_LIMIT` | `500_000` |
| `MIN_EXPIRY_DURATION` | `5 minutes` |
| `MAX_DESCRIPTION_LENGTH` | `1024` |
| `EVALUATION_GRACE_PERIOD` | `1 hours` |

### Owner-mutable

| Parameter | Function | Constraint |
| --------- | -------- | ---------- |
| `platformFeeBp` | `setPlatformFee` | `+ evaluatorFeeBp ≤ 5000` |
| `evaluatorFeeBp` | `setEvaluatorFee` | `+ platformFeeBp ≤ 5000` |
| `treasury` | `setTreasury` | `!= address(0)`; does **not** rewrite snapshotted `fundedTreasury` |
| `whitelistedHooks` | `setHookWhitelist` | `hook != address(0)` |
| `allowedPaymentTokens` | `setPaymentTokenAllowed` | `token != address(0)` |
| `job.hook` | `batchDetachHook` | existing jobs only |
| `owner` | `transferOwnership` / `acceptOwnership` | Ownable2Step |

Fee changes affect future `fund` calls only.

### Token compatibility

Allowlist is **not** a proof of plain ERC-20. FoT, rebasing, ERC-777/1363 hooks, pausable/blacklist tokens can still break accounting **after** `fund`. The delta check is only at `fund`. Admin must vet tokens.

---

## Local Deployment (Anvil)

```bash
anvil --hardfork cancun
```

```bash
export TREASURY=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export PLATFORM_FEE_BP=250
export EVALUATOR_FEE_BP=100

forge script script/DeployERC8183.s.sol:DeployERC8183 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

Then:

```bash
cast send $CORE "setPaymentTokenAllowed(address,bool)" $TOKEN true \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <owner>
```

---

## Testnet / Mainnet

Dry run:

```bash
forge script script/DeployERC8183.s.sol:DeployERC8183 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Broadcast:

```bash
forge script script/DeployERC8183.s.sol:DeployERC8183 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Hardware wallet:

```bash
forge script script/DeployERC8183.s.sol:DeployERC8183 \
  --rpc-url $RPC_URL --ledger --sender $DEPLOYER_ADDRESS \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

`renounceOwnership()` always reverts `Unauthorized()`.

---

## Post-Deployment Verification

```bash
forge verify-contract $CORE_ADDRESS \
  src/ERC8183.sol:ERC8183 \
  --chain-id $CHAIN_ID \
  --constructor-args $(cast abi-encode "constructor(uint256,uint256,address,address)" \
    $PLATFORM_FEE_BP $EVALUATOR_FEE_BP $TREASURY $OWNER) \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

```bash
cast call $CORE "platformFeeBp()(uint256)" --rpc-url $RPC_URL
cast call $CORE "evaluatorFeeBp()(uint256)" --rpc-url $RPC_URL
cast call $CORE "treasury()(address)" --rpc-url $RPC_URL
cast call $CORE "owner()(address)" --rpc-url $RPC_URL
cast call $CORE "supportsInterface(bytes4)(bool)" "0x01ffc9a7" --rpc-url $RPC_URL
```

There is no `jobs(uint256)` getter. Use `getJob(uint256)`. Missing ids revert `JobDoesNotExist`.

---

## Multi-Chain CREATE2

Foundry path: `new ERC8183{salt: salt}(...)` and `computeCreate2Address`. Under `forge script --broadcast` the factory is Arachnid `0x4e59b44847b379578588920cA78FbF26c0B4956C`, **not** the EOA. Predicting with the EOA as deployer will mis-predict.

Same address across chains requires:

- identical compiler bytecode (solc 0.8.34, optimizer 200, `via_ir = false`, same OpenZeppelin version)
- identical salt
- identical CREATE2 factory
- identical `(platformFeeBp_, evaluatorFeeBp_, treasury_, owner_)`

Per-chain treasuries or owners produce per-chain addresses. Per-chain USDC is **post-deploy allowlist**, not a constructor arg — that is why `PAYMENT_TOKEN` is not in CREATE2.

```bash
forge script script/DeployMultiChain.s.sol:DeployMultiChain \
  --sig "predict()" --rpc-url $RPC_URL
```

```bash
chmod +x script/deploy-multichain.sh
export TREASURY=0x...
export PLATFORM_FEE_BP=250
export EVALUATOR_FEE_BP=100
export OWNER=0x...
./script/deploy-multichain.sh
```

---

## Troubleshooting

| Error | Cause | Fix |
| ----- | ----- | --- |
| `ZeroAddress()` | `treasury` is `address(0)` | Provide a valid treasury |
| `FeeTooHigh()` | combined bps > 5000 | Reduce fees |
| `EvmError: NotActivated` | Chain lacks EIP-1153 | Cancun+ chain |
| Address mismatch (CREATE2) | Predicted with EOA deployer | Use forge-std `computeCreate2Address` (Arachnid factory) |

Approximate deploy gas (Ethereum, 200 optimizer runs): ~3,000,000. Run `forge test --gas-report` for `ERC8183`.
