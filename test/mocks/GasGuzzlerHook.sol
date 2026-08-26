// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8183Hook} from "../../src/interfaces/IERC8183Hook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Hook that burns all available gas in beforeAction to test gas limit enforcement.
contract GasGuzzlerHook is IERC8183Hook {
    function supportsInterface(
        bytes4 id
    ) external pure override returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(
        uint256,
        bytes4,
        bytes calldata
    ) external view override {
        uint256 i;
        while (gasleft() > 0) {
            i++;
        }
    }

    function afterAction(
        uint256,
        bytes4,
        bytes calldata
    ) external override {}
}
