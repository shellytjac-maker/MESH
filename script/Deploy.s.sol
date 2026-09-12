pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {USDCPaymaster} from "../src/USDCPaymaster.sol";

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
    }
}