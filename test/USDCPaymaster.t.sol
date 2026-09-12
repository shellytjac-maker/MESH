// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {USDCPaymaster} from "../src/USDCPaymaster.sol";
import {IPaymaster, UserOperation} from "../src/interfaces/IERC4337Minimal.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract USDCPaymasterTest is Test {
    USDCPaymaster paymaster;
    MockUSDC usdc;

    address entryPoint = makeAddr("entryPoint");
    uint256 signerPk = 0x51DE5;
    address signer;
    address account = makeAddr("account");

    function setUp() public {
        signer = vm.addr(signerPk);
        usdc = new MockUSDC();
        paymaster = new USDCPaymaster(entryPoint, address(usdc), signer);

        usdc.mint(account, 10_000_000);
        vm.prank(account);
        usdc.approve(address(paymaster), type(uint256).max);
    }

    function test_validatePaymasterUserOp_acceptsValidSponsorSignature() public {
        UserOperation memory op = _userOp();
        uint256 maxCost = 50_000;
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        op.paymasterAndData = _buildPaymasterData(op, maxCost, validUntil);

        vm.prank(entryPoint);
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, keccak256("hash"), maxCost);

        assertEq(abi.decode(context, (address)), account);
        assertEq(validationData >> 160, validUntil);
    }

    function test_validatePaymasterUserOp_rejectsBadSigner() public {
        UserOperation memory op = _userOp();
        uint256 maxCost = 50_000;
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // sign with a random, non-trusted key
        op.paymasterAndData = _buildPaymasterDataWithKey(op, maxCost, validUntil, 0xBAD5);

        vm.prank(entryPoint);
        vm.expectRevert(USDCPaymaster.InvalidSponsorSignature.selector);
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), maxCost);
    }

    function test_postOp_reimbursesInUSDC() public {
        UserOperation memory op = _userOp();
        uint256 maxCost = 50_000;
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        op.paymasterAndData = _buildPaymasterData(op, maxCost, validUntil);

        vm.prank(entryPoint);
        (bytes memory context,) = paymaster.validatePaymasterUserOp(op, keccak256("hash"), maxCost);

        uint256 balBefore = usdc.balanceOf(address(paymaster));

        vm.prank(entryPoint);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 42_000);

        assertEq(usdc.balanceOf(address(paymaster)) - balBefore, 42_000, "paymaster should be reimbursed exact gas cost");
    }

    function test_postOp_skipsReimbursementIfPostOpReverted() public {
        UserOperation memory op = _userOp();
        bytes memory context = abi.encode(account);

        uint256 balBefore = usdc.balanceOf(address(paymaster));

        vm.prank(entryPoint);
        paymaster.postOp(IPaymaster.PostOpMode.postOpReverted, context, 42_000);

        assertEq(usdc.balanceOf(address(paymaster)), balBefore, "no reimbursement should occur");
    }

    // -----------------------------------------------------------
    // helpers
    // -----------------------------------------------------------

    function _userOp() internal view returns (UserOperation memory op) {
        op.sender = account;
        op.nonce = 0;
    }

    function _buildPaymasterData(UserOperation memory op, uint256 maxCost, uint48 validUntil)
        internal
        view
        returns (bytes memory)
    {
        return _buildPaymasterDataWithKey(op, maxCost, validUntil, signerPk);
    }

    function _buildPaymasterDataWithKey(UserOperation memory op, uint256 maxCost, uint48 validUntil, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 approvalHash = keccak256(abi.encode(op.sender, op.nonce, maxCost, validUntil, block.chainid));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", approvalHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        bytes memory sig = abi.encodePacked(r, s, v);

        return abi.encodePacked(address(paymaster), validUntil, sig);
    }
}
