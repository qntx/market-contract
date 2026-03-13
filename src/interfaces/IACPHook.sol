// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IACPHook — Optional hook interface for ERC-8183 Agentic Commerce
/// @notice Called before and after core actions to enable protocol extensions
///         (validation, reputation, fees) without modifying the core contract.
/// @dev    Uses a generic selector-based interface: new hookable functions simply
///         produce new selector values without changing this interface.
///         claimRefund is deliberately NOT hookable — refunds after expiry cannot
///         be blocked by a malicious hook.
interface IACPHook {
    /// @notice Called before a core action executes.
    /// @dev    MAY revert to prevent the action from executing.
    /// @param jobId    Job identifier.
    /// @param selector The 4-byte function selector of the action being performed.
    /// @param data     ABI-encoded function-specific arguments.
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external;

    /// @notice Called after a core action executes.
    /// @dev    MAY revert to roll back the action. Use with caution.
    /// @param jobId    Job identifier.
    /// @param selector The 4-byte function selector of the action that was performed.
    /// @param data     ABI-encoded function-specific arguments.
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata data
    ) external;
}
