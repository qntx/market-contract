// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IERC8183Hook} from "./interfaces/IERC8183Hook.sol";

/// @title BaseERC8183Hook
/// @notice Convenience router from `beforeAction` / `afterAction` to named virtuals.
/// @dev Selectors are `IERC8183.*.selector`. Unknown selectors no-op.
///      `onlyERC8183` allows the kernel or `getJob(jobId).hook`.
abstract contract BaseERC8183Hook is ERC165, IERC8183Hook {
    address public immutable erc8183Contract;

    error OnlyERC8183Contract();
    error ZeroAddress();

    /// @dev Kernel: `msg.sender == erc8183Contract`. Router: `msg.sender == getJob(jobId).hook`.
    ///      Unknown `jobId` reverts `JobDoesNotExist` from `getJob`.
    modifier onlyERC8183(
        uint256 jobId
    ) {
        _onlyERC8183(jobId);
        _;
    }

    function _onlyERC8183(
        uint256 jobId
    ) internal view {
        if (msg.sender != erc8183Contract) {
            if (msg.sender != IERC8183(erc8183Contract).getJob(jobId).hook) {
                revert OnlyERC8183Contract();
            }
        }
    }

    constructor(
        address erc8183Contract_
    ) {
        if (erc8183Contract_ == address(0)) revert ZeroAddress();
        erc8183Contract = erc8183Contract_;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC8183Hook
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external override onlyERC8183(jobId) {
        if (selector == IERC8183.setBudget.selector) {
            (address caller, address token, uint256 amount, bytes memory optParams) =
                abi.decode(data, (address, address, uint256, bytes));
            _preSetBudget(jobId, caller, token, amount, optParams);
        } else if (selector == IERC8183.fund.selector) {
            (address caller, bytes memory optParams) = abi.decode(data, (address, bytes));
            _preFund(jobId, caller, optParams);
        } else if (selector == IERC8183.submit.selector) {
            (address caller, bytes32 deliverable, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _preSubmit(jobId, caller, deliverable, optParams);
        } else if (selector == IERC8183.complete.selector) {
            (address caller, bytes32 reason, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _preComplete(jobId, caller, reason, optParams);
        } else if (selector == IERC8183.reject.selector) {
            (address caller, bytes32 reason, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _preReject(jobId, caller, reason, optParams);
        } else if (selector == IERC8183.submitClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _preSubmitClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.settleClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _preSettleClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.approveClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _preApproveClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.rejectClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes32, bytes));
            _preRejectClaim(jobId, caller, cumulativeAmount, deliverable, reason, optParams);
        }
    }

    /// @inheritdoc IERC8183Hook
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external override onlyERC8183(jobId) {
        if (selector == IERC8183.setBudget.selector) {
            (address caller, address token, uint256 amount, bytes memory optParams) =
                abi.decode(data, (address, address, uint256, bytes));
            _postSetBudget(jobId, caller, token, amount, optParams);
        } else if (selector == IERC8183.fund.selector) {
            (address caller, bytes memory optParams) = abi.decode(data, (address, bytes));
            _postFund(jobId, caller, optParams);
        } else if (selector == IERC8183.submit.selector) {
            (address caller, bytes32 deliverable, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _postSubmit(jobId, caller, deliverable, optParams);
        } else if (selector == IERC8183.complete.selector) {
            (address caller, bytes32 reason, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _postComplete(jobId, caller, reason, optParams);
        } else if (selector == IERC8183.reject.selector) {
            (address caller, bytes32 reason, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _postReject(jobId, caller, reason, optParams);
        } else if (selector == IERC8183.submitClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _postSubmitClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.settleClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _postSettleClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.approveClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes));
            _postApproveClaim(jobId, caller, cumulativeAmount, deliverable, optParams);
        } else if (selector == IERC8183.rejectClaim.selector) {
            (address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes memory optParams) =
                abi.decode(data, (address, uint256, bytes32, bytes32, bytes));
            _postRejectClaim(jobId, caller, cumulativeAmount, deliverable, reason, optParams);
        }
    }

    function _preSetBudget(
        uint256 jobId,
        address caller,
        address token,
        uint256 amount,
        bytes memory optParams
    ) internal virtual {}

    function _postSetBudget(
        uint256 jobId,
        address caller,
        address token,
        uint256 amount,
        bytes memory optParams
    ) internal virtual {}

    function _preFund(
        uint256 jobId,
        address caller,
        bytes memory optParams
    ) internal virtual {}

    function _postFund(
        uint256 jobId,
        address caller,
        bytes memory optParams
    ) internal virtual {}

    function _preSubmit(
        uint256 jobId,
        address caller,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _postSubmit(
        uint256 jobId,
        address caller,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _preComplete(
        uint256 jobId,
        address caller,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}

    function _postComplete(
        uint256 jobId,
        address caller,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}

    function _preReject(
        uint256 jobId,
        address caller,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}

    function _postReject(
        uint256 jobId,
        address caller,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}

    function _preSubmitClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _postSubmitClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _preSettleClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _postSettleClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _preApproveClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _postApproveClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}

    function _preRejectClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}

    function _postRejectClaim(
        uint256 jobId,
        address caller,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}
}
