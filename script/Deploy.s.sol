// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {USDCPaymaster} from "../src/USDCPaymaster.sol";

/// @notice Deploys AccountFactory + USDCPaymaster to Arc testnet.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url arc_testnet \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
///
/// Required env vars (set in .env, loaded automatically by Foundry):
///   ENTRY_POINT_ADDRESS   - Arc testnet's ERC-4337 EntryPoint address (confirm in docs)
///   USDC_ADDRESS          - Arc testnet USDC contract address
///   SPONSOR_SIGNER_ADDRESS - backend key that co-signs sponsored UserOperations
contract Deploy is Script {
    function run() external {
        address entryPoint = vm.envAddress("ENTRY_POINT_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address sponsorSigner = vm.envAddress("SPONSOR_SIGNER_ADDRESS");

        vm.startBroadcast();

        AccountFactory factory = new AccountFactory(entryPoint);
        console.log("AccountFactory deployed at:", address(factory));

        USDCPaymaster paymaster = new USDCPaymaster(entryPoint, usdc, sponsorSigner);
        console.log("USDCPaymaster deployed at:", address(paymaster));

        vm.stopBroadcast();

        console.log("");
        console.log("Next steps:");
        console.log("1. Fund the paymaster's EntryPoint deposit:");
        console.log("   entryPoint.depositTo{value: X}(address(paymaster))");
        console.log("   (X is denominated in USDC since that's Arc's native gas token)");
        console.log("2. Save these addresses into your client/backend config.");
        console.log("3. Confirm ENTRY_POINT_ADDRESS above actually matches what Arc's");
        console.log("   bundler infra expects before sending real UserOperations.");
    }
}
