# Hook Development (kernel)

Hooks are optional `IERC8183Hook` contracts. The kernel forwards `beforeAction` / `afterAction` with a 500_000 gas stipend. Reverts bubble; hook OOG reverts the parent.

Implement `IERC8183Hook` directly, or inherit `BaseERC8183Hook` and override the named virtuals.

## Interface

```solidity
interface IERC8183Hook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

ERC-165: advertise `type(IERC8183Hook).interfaceId` (`0x7ff6bc9e` = `beforeAction` XOR `afterAction`) **and** `type(IERC165).interfaceId`. The kernel checks this only at `createJob`.

## Hookable vs not

| Function | Hookable |
| -------- | -------- |
| `createJob` | No |
| `setProvider` | No |
| `setPayoutReceiver` | No |
| `setBudget` | Yes |
| `fund` | Yes |
| `submit` | Yes |
| `complete` | Yes |
| `reject` | Yes |
| `submitClaim` | Yes |
| `settleClaim` | Yes |
| `approveClaim` | Yes |
| `rejectClaim` | Yes |
| `claimRefund` | **No** |

Selectors passed to hooks are always the canonical kernel selectors (`this.fund.selector`, etc.), never `msg.sig`.

## Data encoding

`data` always leads with the **caller** (`actor`), then the function-specific fields.

| Function | `data` |
| -------- | ------ |
| `setBudget` | `abi.encode(address caller, address token, uint256 amount, bytes optParams)` |
| `fund` | `abi.encode(address caller, bytes optParams)` |
| `submit` | `abi.encode(address caller, bytes32 deliverable, bytes optParams)` |
| `complete` | `abi.encode(address caller, bytes32 reason, bytes optParams)` |
| `reject` | `abi.encode(address caller, bytes32 reason, bytes optParams)` |
| `submitClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `settleClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `approveClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `rejectClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes optParams)` |

`fund` is **not** raw `optParams`. Decode `(address, bytes)`.

`rejectClaim` decode is `(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes optParams)`. `reason` is the fourth field.

## Canonical selectors

| Function | Selector |
| -------- | -------- |
| `setBudget(uint256,address,uint256,bytes)` | `0xf3302b89` |
| `fund(uint256,address,uint256,bytes)` | `0x1f989ec8` |
| `submit(uint256,bytes32,bytes)` | `0x9e63798d` |
| `complete(uint256,bytes32,bytes)` | `0xd75bbdf3` |
| `reject(uint256,bytes32,bytes)` | `0x41dd26f5` |
| `submitClaim(uint256,uint256,bytes32,bytes)` | `0x5d0e9ca0` |
| `settleClaim(uint256,uint256,bytes32,bytes)` | `0xe8bcf104` |
| `approveClaim(uint256,uint256,bytes32,bytes)` | `0x165fbf71` |
| `rejectClaim(uint256,uint256,bytes32,bytes32,bytes)` | `0xd127c867` |

### `SEL_FUND` warning

`bytes4(keccak256("fund(uint256,uint256,bytes)"))` is `0xd2e13f50` (February ERC
`fund(jobId, expectedBudget, optParams)`). It **will not match** this kernel. Use
`IERC8183.fund.selector` (`0x1f989ec8`). Third-party hook bases that hardcode the
old string miss every `fund` callback. This repo's `src/BaseERC8183Hook.sol` compares
against `IERC8183.*.selector` and routes claim functions.

## `BaseERC8183Hook`

Convenience base. Not part of the ERC. Inherit it and override only the virtuals you need.

```solidity
import {BaseERC8183Hook} from "../src/BaseERC8183Hook.sol";

contract MyHook is BaseERC8183Hook {
    constructor(address core) BaseERC8183Hook(core) {}

    function _preFund(uint256 jobId, address caller, bytes memory optParams) internal override {
        // caller is the kernel actor (client for fund)
    }

    function _preRejectClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes memory optParams
    ) internal override {
        // reason is decoded from the fourth field
    }
}
```

Pass the **kernel** address as `erc8183Contract`. The base ERC-165-advertises `IERC8183Hook` (`0x7ff6bc9e`) and `IERC165`. Unknown selectors no-op so a newer kernel function does not brick an old hook.

### `onlyERC8183(jobId)`

`beforeAction` / `afterAction` revert `OnlyERC8183Contract` unless:

1. `msg.sender == erc8183Contract` (standalone: kernel calls the hook), or
2. `msg.sender == IERC8183(erc8183Contract).getJob(jobId).hook` (router: kernel's `job.hook` is the router; the router calls sub-hooks)

A call that is not the kernel, with a **bogus** `jobId`, reverts `JobDoesNotExist` from `getJob` (this kernel does not return a zeroed job). Valid `jobId` and a caller that is neither the kernel nor `job.hook` reverts `OnlyERC8183Contract`.

### Virtuals

Every virtual takes `address caller` first after `jobId`.

| Action | Pre | Post | Decoded after `caller` |
| ------ | --- | ---- | ---------------------- |
| `setBudget` | `_preSetBudget` | `_postSetBudget` | `token, amount, optParams` |
| `fund` | `_preFund` | `_postFund` | `optParams` |
| `submit` | `_preSubmit` | `_postSubmit` | `deliverable, optParams` |
| `complete` | `_preComplete` | `_postComplete` | `reason, optParams` |
| `reject` | `_preReject` | `_postReject` | `reason, optParams` |
| `submitClaim` | `_preSubmitClaim` | `_postSubmitClaim` | `cumulativeAmount, deliverable, optParams` |
| `settleClaim` | `_preSettleClaim` | `_postSettleClaim` | `cumulativeAmount, deliverable, optParams` |
| `approveClaim` | `_preApproveClaim` | `_postApproveClaim` | `cumulativeAmount, deliverable, optParams` |
| `rejectClaim` | `_preRejectClaim` | `_postRejectClaim` | `cumulativeAmount, deliverable, reason, optParams` |

`createJob`, `setProvider`, `setPayoutReceiver`, and `claimRefund` are not hookable; they never hit these virtuals.

### Bidding / third-party hooks

`setBudget` is **provider-only**. A `BiddingHook` that opens a window via client `setBudget` while `provider == 0` cannot run on this kernel: the client is `Unauthorized`. `setProvider` is not hookable, so bid verification cannot sit there either. Bidding stays off-chain; client `setProvider`, then provider `setBudget`.

Third-party `MultiHookRouter` / `BiddingHook` / `FundTransferHook` / `PrivacyHook` are not vendored here. Point sub-hooks at this `BaseERC8183Hook` (canonical selectors + claim virtuals + router-safe `onlyERC8183`).

## Gas: 500k stipend and 63/64 leftover

`CALL{gas: 500_000}` forwards `min(500_000, 63/64 * remaining)` (EIP-150). If the parent is near its gas limit, the hook receives less than 500k, OOGs, and the parent reverts. Callers must supply ~500k + ~1/63 overhead + core logic.

This is policy, not a bug.

## Liveness

- `claimRefund` is not hookable.
- A reverting hook on `setBudget` / `fund` / `submit` / `complete` / `reject` / `submitClaim` / `settleClaim` / `approveClaim` / `rejectClaim` blocks that call.
- A reverting `rejectClaim` hook can pin a Funded pending claim past `expiredAt` (`claimRefund` → `PendingClaimExists`). Expiry does not clear it. Owner `batchDetachHook`, then `rejectClaim` / `claimRefund`.
- The client chose the hook at `createJob`.

## Minimal example

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8183Hook} from "../src/interfaces/IERC8183Hook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ExampleHook is IERC8183Hook {
    address public immutable core;

    error OnlyKernel();

    constructor(address core_) {
        core = core_;
    }

    function beforeAction(uint256, bytes4, bytes calldata) external view {
        if (msg.sender != core) revert OnlyKernel();
    }

    function afterAction(uint256, bytes4, bytes calldata) external view {
        if (msg.sender != core) revert OnlyKernel();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }
}
```

Whitelist via `setHookWhitelist(hook, true)` before `createJob`.
