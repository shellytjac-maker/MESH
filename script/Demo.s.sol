// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {SessionAccount} from "../src/SessionAccount.sol";
import {USDCPaymaster} from "../src/USDCPaymaster.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Runs the whole Phase 1 story end to end against a local, in-memory
/// EVM -- no real testnet, no bundler, no wallet extension needed. This is
/// the fastest way to *see* the account-abstraction + session-key +
/// paymaster flow actually work before wiring up a real frontend.
///
/// Run with:
///   forge script script/Demo.s.sol -vv
///
/// (No --rpc-url, no --broadcast -- this runs entirely in forge's local
/// simulated EVM and just prints the story to your terminal.)
contract Demo is Script {
    function run() external {
        console.log("");
        console.log("=====================================================");
        console.log(" MESH Micropayments -- Phase 1 Demo");
        console.log("=====================================================");
        console.log("");

        // A stand-in address for the ERC-4337 EntryPoint. On real Arc
        // testnet this would be the actual EntryPoint contract; here we
        // just need *an* address we can impersonate with vm.prank to show
        // the access-control logic working correctly.
        address entryPoint = address(0xE47170e02107);

        address alice = address(0xA11CE);
        address podcastApp = address(0xB0DCA57);

        console.log("Step 1: Deploying the account factory and a mock USDC token...");
        AccountFactory factory = new AccountFactory(entryPoint);
        MockUSDC usdc = new MockUSDC();
        console.log("  AccountFactory deployed at", address(factory));
        console.log("  Mock USDC deployed at     ", address(usdc));
        console.log("");

        console.log("Step 2: Alice's wallet address is computed BEFORE she has an account on-chain...");
        uint256 salt = 1;
        address predicted = factory.getAddress(alice, salt);
        console.log("  Predicted (counterfactual) address:", predicted);

        address aliceAccount = factory.createAccount(alice, salt);
        console.log("  Actual deployed address:           ", aliceAccount);
        console.log("  Match:", predicted == aliceAccount);
        console.log("  (This is why a user can receive funds before ever signing a transaction.)");
        console.log("");

        console.log("Step 3: Funding Alice's account with 5.00 USDC...");
        usdc.mint(aliceAccount, 5_000_000); // 6 decimals
        console.log("  Alice's balance:", usdc.balanceOf(aliceAccount) / 1e4, "cents");
        console.log("");

        console.log("Step 4: Alice authorizes a session key for a podcast app...");
        console.log("  Policy: up to 1.00 USDC total, expires in 7 days, USDC only.");
        address sessionKey = address(0x5E55104E);
        vm.prank(alice);
        SessionAccount(payable(aliceAccount))
            .authorizeSessionKey(
                sessionKey,
                1_000_000, // 1.00 USDC cap
                uint48(block.timestamp + 7 days),
                address(usdc)
            );
        console.log("  Session key authorized. Alice will not need to sign again");
        console.log("  for any single charge within this cap and window.");
        console.log("");

        console.log("Step 5: The podcast app charges Alice 0.10 USDC, three times,");
        console.log("        without asking her to approve each one...");
        for (uint256 i = 1; i <= 3; i++) {
            vm.prank(sessionKey);
            SessionAccount(payable(aliceAccount)).executeSessionSpend(address(usdc), podcastApp, 100_000);
            (uint256 remainingCap,,,) = SessionAccount(payable(aliceAccount)).sessionKeys(sessionKey);
            console.log("  Charge", i, ": 0.10 USDC paid. Remaining session budget (in USDC units):", remainingCap);
        }
        console.log("");

        console.log("Step 6: The podcast app tries to charge MORE than the remaining budget...");
        vm.prank(sessionKey);
        try SessionAccount(payable(aliceAccount)).executeSessionSpend(address(usdc), podcastApp, 1_000_000) {
            console.log("  ERROR: this should not have succeeded!");
        } catch {
            console.log("  Correctly rejected: spend cap exceeded. Alice's remaining funds are safe.");
        }
        console.log("");

        console.log("Step 7: Alice revokes the session key early (e.g. she cancels the subscription)...");
        vm.prank(alice);
        SessionAccount(payable(aliceAccount)).revokeSessionKey(sessionKey);
        vm.prank(sessionKey);
        try SessionAccount(payable(aliceAccount)).executeSessionSpend(address(usdc), podcastApp, 100_000) {
            console.log("  ERROR: this should not have succeeded!");
        } catch {
            console.log("  Correctly rejected: session key is revoked and can no longer spend.");
        }
        console.log("");

        console.log("Step 8: Demonstrating gas sponsorship -- Alice never needs a separate gas token.");
        address sponsorSigner = address(0x51DE5);
        USDCPaymaster paymaster = new USDCPaymaster(entryPoint, address(usdc), sponsorSigner);
        console.log("  USDCPaymaster deployed at", address(paymaster));
        console.log("  On Arc, gas IS USDC, so the paymaster bills and reimburses");
        console.log("  itself in the exact same unit as the payment -- no conversion,");
        console.log("  no price oracle, no separate 'gas token' the user has to hold.");
        console.log("");

        console.log("=====================================================");
        console.log(" Final balances");
        console.log("=====================================================");
        console.log("  Alice's account:", usdc.balanceOf(aliceAccount) / 1e4, "cents");
        console.log("  Podcast app:    ", usdc.balanceOf(podcastApp) / 1e4, "cents");
        console.log("");
        console.log("Demo complete.");
    }
}
