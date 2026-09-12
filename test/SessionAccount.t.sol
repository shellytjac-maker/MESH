// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SessionAccount} from "../src/SessionAccount.sol";
import {UserOperation} from "../src/interfaces/IERC4337Minimal.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract SessionAccountTest is Test {
    SessionAccount account;
    MockUSDC usdc;

    address entryPoint = makeAddr("entryPoint");
    uint256 ownerKey = 0xA11CE;
    address owner;

    uint256 sessionKeyPk = 0x5E55;
    address sessionKey;

    address recipient = makeAddr("recipient");

    function setUp() public {
        owner = vm.addr(ownerKey);
        sessionKey = vm.addr(sessionKeyPk);

        account = new SessionAccount(entryPoint, owner);
        usdc = new MockUSDC();

        usdc.mint(address(account), 1_000_000); // 1.0 USDC at 6 decimals
    }

    // -----------------------------------------------------------
    // validateUserOp gating
    // -----------------------------------------------------------

    function test_validateUserOp_revertsIfNotEntryPoint() public {
        UserOperation memory op = _emptyUserOp();
        vm.expectRevert(SessionAccount.NotEntryPoint.selector);
        account.validateUserOp(op, bytes32(0), 0);
    }

    function test_validateUserOp_acceptsOwnerSignature() public {
        UserOperation memory op = _emptyUserOp();
        bytes32 userOpHash = keccak256("test-op");
        op.signature = _signHash(ownerKey, userOpHash);

        vm.prank(entryPoint);
        uint256 validation = account.validateUserOp(op, userOpHash, 0);
        assertEq(validation, 0, "owner signature should validate");
    }

    function test_validateUserOp_rejectsUnknownSigner() public {
        UserOperation memory op = _emptyUserOp();
        bytes32 userOpHash = keccak256("test-op");
        op.signature = _signHash(0xBAD, userOpHash); // random unauthorized key

        vm.prank(entryPoint);
        uint256 validation = account.validateUserOp(op, userOpHash, 0);
        assertEq(validation, 1, "unknown signer should be rejected");
    }

    // -----------------------------------------------------------
    // Session key lifecycle
    // -----------------------------------------------------------

    function test_owner_canAuthorizeSessionKey() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 days), address(usdc));

        (uint256 cap, uint48 validUntil, address token, bool revoked) = account.sessionKeys(sessionKey);
        assertEq(cap, 500_000);
        assertEq(token, address(usdc));
        assertFalse(revoked);
        assertGt(validUntil, block.timestamp);
    }

    function test_nonOwner_cannotAuthorizeSessionKey() public {
        vm.prank(recipient);
        vm.expectRevert(SessionAccount.NotOwner.selector);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 days), address(usdc));
    }

    function test_sessionKey_canSpendWithinCap() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 days), address(usdc));

        vm.prank(sessionKey);
        account.executeSessionSpend(address(usdc), recipient, 100_000);

        assertEq(usdc.balanceOf(recipient), 100_000);
        (uint256 remainingCap,,,) = account.sessionKeys(sessionKey);
        assertEq(remainingCap, 400_000, "cap should decrement by spent amount");
    }

    function test_sessionKey_cannotExceedCap() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 100_000, uint48(block.timestamp + 1 days), address(usdc));

        vm.prank(sessionKey);
        vm.expectRevert(SessionAccount.SpendCapExceeded.selector);
        account.executeSessionSpend(address(usdc), recipient, 100_001);
    }

    function test_sessionKey_cannotSpendAfterExpiry() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 hours), address(usdc));

        vm.warp(block.timestamp + 2 hours);

        vm.prank(sessionKey);
        vm.expectRevert(SessionAccount.SessionKeyExpired.selector);
        account.executeSessionSpend(address(usdc), recipient, 1_000);
    }

    function test_sessionKey_cannotSpendAfterRevoke() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 days), address(usdc));

        vm.prank(owner);
        account.revokeSessionKey(sessionKey);

        vm.prank(sessionKey);
        vm.expectRevert(SessionAccount.SessionKeyInvalid.selector);
        account.executeSessionSpend(address(usdc), recipient, 1_000);
    }

    function test_sessionKey_wrongTokenReverts() public {
        vm.prank(owner);
        account.authorizeSessionKey(sessionKey, 500_000, uint48(block.timestamp + 1 days), address(usdc));

        address otherToken = makeAddr("otherToken");
        vm.prank(sessionKey);
        vm.expectRevert(SessionAccount.SessionKeyInvalid.selector);
        account.executeSessionSpend(otherToken, recipient, 1_000);
    }

    // -----------------------------------------------------------
    // helpers
    // -----------------------------------------------------------

    function _emptyUserOp() internal view returns (UserOperation memory op) {
        op.sender = address(account);
        op.nonce = 0;
        op.callGasLimit = 100_000;
        op.verificationGasLimit = 100_000;
        op.preVerificationGas = 21_000;
        op.maxFeePerGas = 1 gwei;
        op.maxPriorityFeePerGas = 1 gwei;
    }

    function _signHash(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        return abi.encodePacked(r, s, v);
    }
}
