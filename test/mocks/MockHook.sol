// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IACPHook} from "../../src/interfaces/IACPHook.sol";

/// @dev Configurable mock hook for testing beforeAction/afterAction callbacks.
contract MockHook is IACPHook {
    bool public shouldRevertBefore;
    bool public shouldRevertAfter;

    uint256 public beforeCallCount;
    uint256 public afterCallCount;

    bytes4 public lastBeforeSelector;
    bytes4 public lastAfterSelector;
    uint256 public lastBeforeJobId;
    uint256 public lastAfterJobId;
    address public lastBeforeCaller;
    address public lastAfterCaller;
    bytes public lastBeforeOptParams;
    bytes public lastAfterOptParams;

    function setShouldRevertBefore(
        bool val
    ) external {
        shouldRevertBefore = val;
    }

    function setShouldRevertAfter(
        bool val
    ) external {
        shouldRevertAfter = val;
    }

    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        address caller,
        bytes calldata optParams
    ) external override returns (bytes memory) {
        if (shouldRevertBefore) revert("MockHook: beforeAction reverted");
        beforeCallCount++;
        lastBeforeJobId = jobId;
        lastBeforeSelector = selector;
        lastBeforeCaller = caller;
        lastBeforeOptParams = optParams;
        return "";
    }

    function afterAction(
        uint256 jobId,
        bytes4 selector,
        address caller,
        bytes calldata optParams
    ) external override returns (bytes memory) {
        if (shouldRevertAfter) revert("MockHook: afterAction reverted");
        afterCallCount++;
        lastAfterJobId = jobId;
        lastAfterSelector = selector;
        lastAfterCaller = caller;
        lastAfterOptParams = optParams;
        return "";
    }
}
