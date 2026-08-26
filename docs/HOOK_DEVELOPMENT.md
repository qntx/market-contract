# Hook Development (kernel)

Hooks are optional `IERC8183Hook` contracts. The kernel forwards `beforeAction` / `afterAction` with a 500_000 gas stipend. Reverts bubble; hook OOG reverts the parent.

A convenience `BaseERC8183Hook` router is not in this kernel. Implement `IERC8183Hook` directly.

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

`fund` is **not** raw `optParams`. Decode `(address, bytes)`.

## Canonical selectors

| Function | Selector |
| -------- | -------- |
| `setBudget(uint256,address,uint256,bytes)` | `0xf3302b89` |
| `fund(uint256,address,uint256,bytes)` | `0x1f989ec8` |
| `submit(uint256,bytes32,bytes)` | `0x9e63798d` |
| `complete(uint256,bytes32,bytes)` | `0xd75bbdf3` |
| `reject(uint256,bytes32,bytes)` | `0x41dd26f5` |

### `SEL_FUND` warning

`bytes4(keccak256("fund(uint256,uint256,bytes)"))` is `0xd2e13f50` (February ABI). It **will not match** this kernel. Use `IERC8183.fund.selector` (`0x1f989ec8`). Third-party hook bases that hardcode the old string will miss every `fund` callback.

## Gas: 500k stipend and 63/64 leftover

`CALL{gas: 500_000}` forwards `min(500_000, 63/64 * remaining)` (EIP-150). If the parent is near its gas limit, the hook receives less than 500k, OOGs, and the parent reverts. Callers must supply ~500k + ~1/63 overhead + core logic.

This is policy, not a bug.

## Liveness

- `claimRefund` cannot be blocked by a hook.
- A reverting hook on `setBudget` / `fund` / `submit` / `complete` / `reject` blocks that call until the job expires or the owner calls `batchDetachHook`.
- The client chose the hook at `createJob`.

## Minimal example

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8183Hook} from "../src/interfaces/IERC8183Hook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ExampleHook is IERC8183Hook {
    address public immutable core;

    constructor(address core_) {
        core = core_;
    }

    function beforeAction(uint256, bytes4, bytes calldata) external view {
        require(msg.sender == core, "only kernel");
    }

    function afterAction(uint256, bytes4, bytes calldata) external view {
        require(msg.sender == core, "only kernel");
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }
}
```

Whitelist via `setHookWhitelist(hook, true)` before `createJob`.
