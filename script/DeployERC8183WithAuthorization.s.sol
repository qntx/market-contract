// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC8183WithAuthorization} from "../src/ERC8183WithAuthorization.sol";

/// @title DeployERC8183WithAuthorization — single-chain deployment of the authorization kernel
/// @dev Same constructor args as `ERC8183`. Different bytecode ⇒ different address.
///
///   forge script script/DeployERC8183WithAuthorization.s.sol:DeployERC8183WithAuthorization \
///     --rpc-url $RPC_URL --broadcast --verify
///
///   Required env vars:
///     TREASURY         — Platform fee recipient
///     PLATFORM_FEE_BP  — Platform fee in basis points (e.g. 250 = 2.5%)
///     EVALUATOR_FEE_BP — Evaluator fee in basis points (e.g. 100 = 1%)
///     OWNER            — Contract owner (optional, defaults to deployer)
///     PAYMENT_TOKEN    — Optional; if set, allowlisted post-deploy
contract DeployERC8183WithAuthorization is Script {
    function run() external {
        address treasury = vm.envAddress("TREASURY");
        uint256 platformFeeBp = vm.envUint("PLATFORM_FEE_BP");
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(0));
        address owner = vm.envOr("OWNER", msg.sender);

        vm.startBroadcast();

        ERC8183WithAuthorization core = new ERC8183WithAuthorization(platformFeeBp, evaluatorFeeBp, treasury, owner);

        address paymentToken = vm.envOr("PAYMENT_TOKEN", address(0));
        bool allowlisted;
        if (paymentToken != address(0) && owner == msg.sender) {
            core.setPaymentTokenAllowed(paymentToken, true);
            allowlisted = true;
        }

        vm.stopBroadcast();

        console.log("ERC8183WithAuthorization deployed at:", address(core));
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
}
