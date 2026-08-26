// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IERC8183Hook
/// @notice Optional before/after callbacks on hookable ERC-8183 actions.
/// @dev Implementations MUST ERC-165-advertise `type(IERC8183Hook).interfaceId`
///      (`0x7ff6bc9e`) and `type(IERC165).interfaceId`.
interface IERC8183Hook is IERC165 {
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external;

    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external;
}
