// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Unique recipient address used with `ArmableRevertToken`.
contract RevertingTreasury {
    error TreasuryRejected();
}

/// @dev ERC-20 that can block transfers to a chosen recipient after `fund`.
contract ArmableRevertToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("ARM", "ARM") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setBlocked(
        address account,
        bool status
    ) external {
        blocked[account] = status;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (blocked[to]) revert RevertingTreasury.TreasuryRejected();
        super._update(from, to, value);
    }
}
