// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IACPHook} from "./interfaces/IACPHook.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title BaseACPHook — Convenience base for ERC-8183 hook development
/// @notice Routes beforeAction/afterAction to named virtual functions. Override what you need.
/// @dev    Data encoding per selector (as produced by AgenticCommerce):
///           setProvider : abi.encode(address provider, bytes optParams)
///           setBudget   : abi.encode(uint256 amount, bytes optParams)
///           fund        : optParams (raw bytes)
///           submit      : abi.encode(bytes32 deliverable, bytes optParams)
///           complete    : abi.encode(bytes32 reason, bytes optParams)
///           reject      : abi.encode(bytes32 reason, bytes optParams)
abstract contract BaseACPHook is IACPHook {
    address public immutable ACP;

    error OnlyAcp();

    modifier onlyAcp() {
        _checkAcp();
        _;
    }

    function _checkAcp() internal view {
        if (msg.sender != ACP) revert OnlyAcp();
    }

    constructor(
        address acp_
    ) {
        ACP = acp_;
    }

    bytes4 private constant _SEL_SET_PROVIDER = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 private constant _SEL_SET_BUDGET = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 private constant _SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 private constant _SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 private constant _SEL_COMPLETE = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 private constant _SEL_REJECT = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    /// @inheritdoc IACPHook
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external override onlyAcp {
        if (selector == _SEL_SET_PROVIDER) {
            (address provider_, bytes memory optParams) = abi.decode(data, (address, bytes));
            _preSetProvider(jobId, provider_, optParams);
        } else if (selector == _SEL_SET_BUDGET) {
            (uint256 amount, bytes memory optParams) = abi.decode(data, (uint256, bytes));
            _preSetBudget(jobId, amount, optParams);
        } else if (selector == _SEL_FUND) {
            _preFund(jobId, data);
        } else if (selector == _SEL_SUBMIT) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _preSubmit(jobId, deliverable, optParams);
        } else if (selector == _SEL_COMPLETE) {
            (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _preComplete(jobId, reason, optParams);
        } else if (selector == _SEL_REJECT) {
            (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _preReject(jobId, reason, optParams);
        }
    }

    /// @inheritdoc IACPHook
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external override onlyAcp {
        if (selector == _SEL_SET_PROVIDER) {
            (address provider_, bytes memory optParams) = abi.decode(data, (address, bytes));
            _postSetProvider(jobId, provider_, optParams);
        } else if (selector == _SEL_SET_BUDGET) {
            (uint256 amount, bytes memory optParams) = abi.decode(data, (uint256, bytes));
            _postSetBudget(jobId, amount, optParams);
        } else if (selector == _SEL_FUND) {
            _postFund(jobId, data);
        } else if (selector == _SEL_SUBMIT) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _postSubmit(jobId, deliverable, optParams);
        } else if (selector == _SEL_COMPLETE) {
            (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _postComplete(jobId, reason, optParams);
        } else if (selector == _SEL_REJECT) {
            (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            _postReject(jobId, reason, optParams);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IACPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Read full job data from the ACP contract.
    function _getJob(
        uint256 jobId
    ) internal view returns (IERC8183.Job memory) {
        return IERC8183(ACP).getJob(jobId);
    }

    function _preSetProvider(
        uint256 jobId,
        address provider_,
        bytes memory optParams
    ) internal virtual {}
    function _postSetProvider(
        uint256 jobId,
        address provider_,
        bytes memory optParams
    ) internal virtual {}
    function _preSetBudget(
        uint256 jobId,
        uint256 amount,
        bytes memory optParams
    ) internal virtual {}
    function _postSetBudget(
        uint256 jobId,
        uint256 amount,
        bytes memory optParams
    ) internal virtual {}
    function _preFund(
        uint256 jobId,
        bytes memory optParams
    ) internal virtual {}
    function _postFund(
        uint256 jobId,
        bytes memory optParams
    ) internal virtual {}
    function _preSubmit(
        uint256 jobId,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}
    function _postSubmit(
        uint256 jobId,
        bytes32 deliverable,
        bytes memory optParams
    ) internal virtual {}
    function _preComplete(
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}
    function _postComplete(
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}
    function _preReject(
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}
    function _postReject(
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams
    ) internal virtual {}
}
