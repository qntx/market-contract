// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC8183} from "../src/ERC8183.sol";

/// @title DeployMultiChain — CREATE2 deterministic multi-chain deployment
/// @dev Deploys ERC8183 with Foundry's CREATE2 path. Under `--broadcast` the
///      factory is Arachnid `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
///      Address binds `(platformFeeBp, evaluatorFeeBp, treasury, owner)` plus
///      bytecode — not the per-chain payment token.
///
/// Usage:
///   forge script script/DeployMultiChain.s.sol:DeployMultiChain \
///        --rpc-url $RPC_URL --broadcast --verify
///   forge script script/DeployMultiChain.s.sol:DeployMultiChain --sig "predict()"
///   ./script/deploy-multichain.sh
///
/// Required env vars:
///   TREASURY         — Platform fee recipient
///   PLATFORM_FEE_BP  — Platform fee in basis points
///   EVALUATOR_FEE_BP — Evaluator fee in basis points
///   OWNER            — Contract owner (optional, defaults to deployer)
///   SALT             — CREATE2 salt (optional, defaults to 0x01)
///   PAYMENT_TOKEN    — Optional; allowlisted post-deploy (chain-specific)
contract DeployMultiChain is Script {
    error AddressMismatch();

    function run() external {
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(1)));

        bytes memory creationCode =
            abi.encodePacked(type(ERC8183).creationCode, abi.encode(platformFeeBp, evaluatorFeeBp, treasury, owner));

        address predicted = computeCreate2Address(salt, keccak256(creationCode));

        console.log("Chain ID:", block.chainid);
        console.log("Predicted address:", predicted);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast();

        ERC8183 core = new ERC8183{salt: salt}(platformFeeBp, evaluatorFeeBp, treasury, owner);

        address paymentToken = vm.envOr("PAYMENT_TOKEN", address(0));
        bool allowlisted;
        if (paymentToken != address(0) && owner == msg.sender) {
            core.setPaymentTokenAllowed(paymentToken, true);
            allowlisted = true;
        }

        vm.stopBroadcast();

        if (address(core) != predicted) revert AddressMismatch();

        console.log("");
        console.log("ERC8183 deployed at:", address(core));
        console.log("  treasury:", treasury);
        console.log("  platformFeeBp:", platformFeeBp);
        console.log("  evaluatorFeeBp:", evaluatorFeeBp);
        console.log("  owner:", owner);
        if (allowlisted) {
            console.log("  allowlisted token:", paymentToken);
        } else if (paymentToken != address(0)) {
            console.log(
                "  PAYMENT_TOKEN not allowlisted (OWNER is not broadcaster); call setPaymentTokenAllowed after deploy"
            );
        }
    }

    /// @notice Predict CREATE2 address before deployment
    function predict() external view {
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(1)));

        bytes memory creationCode =
            abi.encodePacked(type(ERC8183).creationCode, abi.encode(platformFeeBp, evaluatorFeeBp, treasury, owner));

        address predicted = computeCreate2Address(salt, keccak256(creationCode));

        console.log("Predicted address:", predicted);
        console.log("Chain ID:", block.chainid);
        console.log("Salt:", vm.toString(salt));
    }
}
