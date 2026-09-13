// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymaster, UserOperation} from "./interfaces/IERC4337Minimal.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title USDCPaymaster
/// @notice Sponsors gas for UserOperations, denominated directly in USDC.
/// Because Arc's native gas token IS USDC, this paymaster does not need a
/// price oracle or conversion math the way an ETH-gas-chain paymaster would
/// -- `actualGasCost` from the EntryPoint is already in the same unit we
/// bill the user in. That's a real simplification specific to building on
/// Arc.
///
/// Sponsorship policy here is a signed-offchain-approval pattern: a backend
/// service co-signs UserOperations it's willing to sponsor (e.g. "first 50
/// transactions free", "sponsor anything under $1", fraud/rate-limit
/// checks done off-chain). Swap `trustedSigner` verification for whatever
/// on-chain policy you want once you have real usage data.
contract USDCPaymaster is IPaymaster {
    using ECDSA for bytes32;

    address public immutable entryPoint;
    address public immutable usdc;
    address public trustedSigner;
    address public owner;

    event Sponsored(address indexed account, uint256 actualGasCost);

    error NotEntryPoint();
    error NotOwner();
    error InvalidSponsorSignature();
    error ReimbursementFailed();

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _entryPoint, address _usdc, address _trustedSigner) {
        entryPoint = _entryPoint;
        usdc = _usdc;
        trustedSigner = _trustedSigner;
        owner = msg.sender;
    }

    /// @dev paymasterAndData layout: [paymaster address][uint48 validUntil][signature]
    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        (uint48 validUntil, bytes memory sig) = _decodePaymasterData(userOp.paymasterAndData);

        bytes32 approvalHash = keccak256(abi.encode(userOp.sender, userOp.nonce, maxCost, validUntil, block.chainid));
        address signer = MessageHashUtils.toEthSignedMessageHash(approvalHash).recover(sig);

        if (signer != trustedSigner) revert InvalidSponsorSignature();

        // packed validationData: (validAfter=0, validUntil, sigFailed=0)
        validationData = uint256(validUntil) << 160;
        context = abi.encode(userOp.sender);
    }

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) external override onlyEntryPoint {
        if (mode == PostOpMode.postOpReverted) return;

        address account = abi.decode(context, (address));

        // Pull reimbursement in USDC from the user's smart account.
        // Requires the account to have approved this paymaster beforehand,
        // or -- cleaner for the shielded-pool version in Phase 2+ -- have
        // the shielded pool itself deduct a fee note and forward it here.
        bool ok = IERC20(usdc).transferFrom(account, address(this), actualGasCost);
        if (!ok) revert ReimbursementFailed();

        emit Sponsored(account, actualGasCost);
    }

    function setTrustedSigner(address newSigner) external onlyOwner {
        trustedSigner = newSigner;
    }

    function _decodePaymasterData(bytes calldata data) internal pure returns (uint48 validUntil, bytes memory sig) {
        // skip first 20 bytes (paymaster address, handled by EntryPoint already)
        validUntil = uint48(bytes6(data[20:26]));
        sig = data[26:];
    }
}
