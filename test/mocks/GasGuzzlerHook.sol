// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IACPHook} from "../../src/interfaces/IACPHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Hook that burns all available gas in beforeAction to test gas limit enforcement.
contract GasGuzzlerHook is IACPHook {
    function supportsInterface(
        bytes4 id
    ) external pure override returns (bool) {
        return id == type(IACPHook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(
        uint256,
        bytes4,
        bytes calldata
    ) external view override {
        // Burn gas until out-of-gas
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
