// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IDisburser
/// @notice Optional payout-receiver callback after ERC-8183 transfers net funds.
/// @dev Receivers that want the callback MUST ERC-165-advertise
///      `type(IDisburser).interfaceId` (`0x74dbc6a9`). A reverting
///      `onDisbursement` rolls back the parent settlement, including fees.
interface IDisburser is IERC165 {
    function onDisbursement(
        uint256 jobId,
        bytes4 selector,
        address token,
        uint256 amount,
        bytes calldata data
    ) external;
}
