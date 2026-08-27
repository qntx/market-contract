// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Credits the recipient more than `amount` on every transfer.
contract MockInflatingToken is ERC20 {
    constructor() ERC20("Inflating", "INFL") {}

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
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            super._update(address(0), to, 1);
        }
    }
}
