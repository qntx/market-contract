// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only ERC20 that burns 1% of every transfer.
contract MockFeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BP = 100;

    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BP) / 10_000;
        uint256 sendAmount = value - fee;
        super._update(from, address(0), fee);
        super._update(from, to, sendAmount);
    }
}
