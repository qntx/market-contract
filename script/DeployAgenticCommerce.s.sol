// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AgenticCommerce} from "../src/AgenticCommerce.sol";

/// @title DeployAgenticCommerce — Deployment script for ERC-8183 AgenticCommerce
/// @dev Usage:
///   forge script script/DeployAgenticCommerce.s.sol:DeployAgenticCommerce \
///     --rpc-url $RPC_URL --broadcast --verify
///
///   Required env vars:
///     PAYMENT_TOKEN  — ERC-20 token address for escrow
///     TREASURY       — Platform fee recipient address
///     PLATFORM_FEE_BP  — Platform fee in basis points (e.g. 250 = 2.5%)
///     EVALUATOR_FEE_BP — Evaluator fee in basis points (e.g. 100 = 1%)
///     OWNER            — Contract owner address (optional, defaults to deployer)
contract DeployAgenticCommerce is Script {
    function run() external {
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);

        vm.startBroadcast();

        AgenticCommerce ac = new AgenticCommerce(paymentToken, platformFeeBp, evaluatorFeeBp, treasury, owner);

        vm.stopBroadcast();

        console.log("AgenticCommerce deployed at:", address(ac));
        console.log("  paymentToken:", paymentToken);
        console.log("  treasury:", treasury);
        console.log("  platformFeeBp:", platformFeeBp);
        console.log("  evaluatorFeeBp:", evaluatorFeeBp);
        console.log("  owner:", owner);
    }
}
