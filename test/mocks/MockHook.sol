// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IACPHook} from "../../src/interfaces/IACPHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Configurable mock hook for testing beforeAction/afterAction callbacks.
contract MockHook is IACPHook {
    bool public revertBefore;
    bool public revertAfter;

    uint256 public beforeCalls;
    uint256 public afterCalls;

    uint256 public lastJobId;
    bytes4 public lastSelector;
    bytes public lastData;

    function setRevertBefore(
        bool v
    ) external {
        revertBefore = v;
    }

    function setRevertAfter(
        bool v
    ) external {
        revertAfter = v;
    }

    function supportsInterface(
        bytes4 id
    ) external pure override returns (bool) {
        return id == type(IACPHook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(
        uint256 jobId,
        bytes4 sel,
        bytes calldata data
    ) external override {
        if (revertBefore) revert("hook:before");
        beforeCalls++;
        lastJobId = jobId;
        lastSelector = sel;
        lastData = data;
    }

    function afterAction(
        uint256 jobId,
        bytes4 sel,
        bytes calldata data
    ) external override {
        if (revertAfter) revert("hook:after");
        afterCalls++;
        lastJobId = jobId;
        lastSelector = sel;
        lastData = data;
    }
}
