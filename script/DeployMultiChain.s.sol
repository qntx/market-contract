// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AgenticCommerce} from "../src/AgenticCommerce.sol";

/// @title DeployMultiChain — CREATE2 deterministic multi-chain deployment
/// @dev Deploys AgenticCommerce to multiple chains with identical addresses.
///
/// Usage:
///   1. Create config file: deployments/multichain.json
///   2. Run: forge script script/DeployMultiChain.s.sol:DeployMultiChain \
///        --rpc-url $RPC_URL --broadcast --verify
///
/// Or deploy to all chains in sequence:
///   ./script/deploy-multichain.sh
///
/// Required env vars:
///   PAYMENT_TOKEN    — ERC-20 token address (chain-specific)
///   TREASURY         — Platform fee recipient
///   PLATFORM_FEE_BP  — Platform fee in basis points
///   EVALUATOR_FEE_BP — Evaluator fee in basis points
///   OWNER            — Contract owner (optional, defaults to deployer)
///   SALT             — CREATE2 salt (optional, defaults to 0x01)
contract DeployMultiChain is Script {
    bytes32 public constant DEFAULT_SALT = bytes32(uint256(1));

    function run() external {
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(1)));

        bytes memory creationCode = abi.encodePacked(
            type(AgenticCommerce).creationCode, abi.encode(paymentToken, platformFeeBp, evaluatorFeeBp, treasury, owner)
        );

        address predicted = computeCreate2Address(salt, keccak256(creationCode));

        console.log("Chain ID:", block.chainid);
        console.log("Predicted address:", predicted);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast();

        AgenticCommerce ac =
            new AgenticCommerce{salt: salt}(paymentToken, platformFeeBp, evaluatorFeeBp, treasury, owner);

        vm.stopBroadcast();

        require(address(ac) == predicted, "Address mismatch");

        console.log("");
        console.log("AgenticCommerce deployed at:", address(ac));
        console.log("  paymentToken:", paymentToken);
        console.log("  treasury:", treasury);
        console.log("  platformFeeBp:", platformFeeBp);
        console.log("  evaluatorFeeBp:", evaluatorFeeBp);
        console.log("  owner:", owner);
    }

    /// @notice Predict CREATE2 address before deployment
    function predict() external view {
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(1)));

        bytes memory creationCode = abi.encodePacked(
            type(AgenticCommerce).creationCode, abi.encode(paymentToken, platformFeeBp, evaluatorFeeBp, treasury, owner)
        );

        address predicted = computeCreate2Address(salt, keccak256(creationCode));

        console.log("Predicted address:", predicted);
        console.log("Chain ID:", block.chainid);
        console.log("Salt:", vm.toString(salt));
    }
}
