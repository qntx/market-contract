// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC8183} from "../../src/ERC8183.sol";

/// @dev Malicious ERC-20 that attempts to re-enter ERC8183 on transfer.
contract ReentrantToken is ERC20 {
    address public target;
    uint256 public attackJobId;
    bool public armed;

    constructor() ERC20("REENTER", "REENTER") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function arm(
        address target_,
        uint256 jobId_
    ) external {
        target = target_;
        attackJobId = jobId_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (armed && to != address(0)) {
            armed = false;
            try ERC8183(target).claimRefund(attackJobId) {} catch {}
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (armed && to != address(0)) {
            armed = false;
            try ERC8183(target).claimRefund(attackJobId) {} catch {}
        }
        return super.transferFrom(from, to, amount);
    }
}
