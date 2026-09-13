// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccount, UserOperation} from "./interfaces/IERC4337Minimal.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SessionAccount
/// @notice ERC-4337 smart account for the micropayments wallet.
///
/// v1 (this file) signs with a plain ECDSA owner key so we can get the whole
/// AA + paymaster + Arc-testnet pipeline working end to end. Passkey
/// (WebAuthn / secp256r1) signing is the next swap-in: replace
/// `_validateOwnerSignature` with a P256 verifier (precompile if Arc
/// supports EIP-7212, otherwise a library like FreshCryptoLib) once that's
/// confirmed against Arc's docs. Nothing else in this contract needs to
/// change for that swap.
///
/// Session keys: a user can authorize a secondary key with a spend cap and
/// expiry, so repeat micropayments (tips, pay-per-view, subscriptions) don't
/// need a fresh owner signature each time. This is transparent-money logic
/// in Phase 1 -- in Phase 2+ the "spend" a session key authorizes becomes a
/// Tier-B note-aggregation step against the shielded pool instead of a raw
/// ERC20 transfer.
contract SessionAccount is IAccount {
    using ECDSA for bytes32;

    address public owner;
    address public immutable entryPoint;

    struct SessionKey {
        uint256 spendCap; // remaining budget, in the token's smallest unit
        uint48 validUntil; // unix timestamp
        address allowedToken; // token this session key may move (e.g. USDC)
        bool revoked;
    }

    mapping(address => SessionKey) public sessionKeys;

    event SessionKeyAuthorized(address indexed key, uint256 spendCap, uint48 validUntil, address token);
    event SessionKeyRevoked(address indexed key);
    event SessionSpend(address indexed key, address indexed token, address indexed to, uint256 amount);

    error NotEntryPoint();
    error NotOwner();
    error SessionKeyInvalid();
    error SessionKeyExpired();
    error SpendCapExceeded();

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        _;
    }

    constructor(address _entryPoint, address _owner) {
        entryPoint = _entryPoint;
        owner = _owner;
    }

    // ---------------------------------------------------------------
    // ERC-4337 required entrypoint
    // ---------------------------------------------------------------

    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        onlyEntryPoint
        returns (uint256 validationData)
    {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address recovered = ethSignedHash.recover(userOp.signature);

        if (recovered != owner) {
            // Not the owner -- check if it's an authorized, unexpired session key.
            SessionKey storage sk = sessionKeys[recovered];
            if (sk.validUntil == 0 || sk.revoked) {
                return 1; // signature invalid
            }
            if (block.timestamp > sk.validUntil) {
                return 1; // expired
            }
            // Session key signature is valid at the ERC-4337 level; the actual
            // spend-cap check happens in `executeSessionSpend` at call time so
            // it accounts for the real amount being moved, not just that a
            // signature exists.
        }

        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            require(ok, "prefund failed");
        }

        return 0;
    }

    // ---------------------------------------------------------------
    // Owner-controlled account management
    // ---------------------------------------------------------------

    function authorizeSessionKey(address key, uint256 spendCap, uint48 validUntil, address token) external onlyOwner {
        sessionKeys[key] = SessionKey({spendCap: spendCap, validUntil: validUntil, allowedToken: token, revoked: false});
        emit SessionKeyAuthorized(key, spendCap, validUntil, token);
    }

    function revokeSessionKey(address key) external onlyOwner {
        sessionKeys[key].revoked = true;
        emit SessionKeyRevoked(key);
    }

    /// @notice Generic call, for the owner. Session keys must go through
    /// `executeSessionSpend` so the spend cap is enforced on-chain.
    function execute(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "call reverted");
        return ret;
    }

    /// @notice Session-key-gated ERC20 transfer with an enforced running cap.
    /// This is the Phase 1 stand-in for what becomes a Tier-B note-aggregation
    /// step once the shielded pool exists.
    function executeSessionSpend(address token, address to, uint256 amount) external {
        SessionKey storage sk = sessionKeys[msg.sender];
        if (sk.validUntil == 0 || sk.revoked) revert SessionKeyInvalid();
        if (block.timestamp > sk.validUntil) revert SessionKeyExpired();
        if (sk.allowedToken != token) revert SessionKeyInvalid();
        if (amount > sk.spendCap) revert SpendCapExceeded();

        sk.spendCap -= amount;

        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "token transfer failed");

        emit SessionSpend(msg.sender, token, to, amount);
    }

    receive() external payable {}
}
