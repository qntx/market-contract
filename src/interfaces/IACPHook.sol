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
    /// @param jobId     Job identifier.
    /// @param selector  The 4-byte function selector of the action being performed.
    /// @param caller    The address initiating the action (msg.sender of the core call).
    /// @param optParams Arbitrary data forwarded from the core function call.
    /// @return Arbitrary data (unused by core protocol; available for hook composition).
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        address caller,
        bytes calldata optParams
    ) external returns (bytes memory);

    /// @notice Called after a core action executes.
    /// @dev    MAY revert to roll back the action. Use with caution.
    /// @param jobId     Job identifier.
    /// @param selector  The 4-byte function selector of the action that was performed.
    /// @param caller    The address that initiated the action.
    /// @param optParams Arbitrary data forwarded from the core function call.
    /// @return Arbitrary data (unused by core protocol; available for hook composition).
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        address caller,
        bytes calldata optParams
    ) external returns (bytes memory);
}
