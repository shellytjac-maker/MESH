// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SessionAccount} from "./SessionAccount.sol";

/// @title AccountFactory
/// @notice Deploys SessionAccounts deterministically via CREATE2, so a
/// user's address can be counterfactually known (and paid into) before
/// their account is actually deployed on-chain -- standard ERC-4337 pattern,
/// referenced from a wallet's `initCode`.
contract AccountFactory {
    address public immutable entryPoint;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    function createAccount(address owner, uint256 salt) external returns (address account) {
        address predicted = getAddress(owner, salt);
        if (predicted.code.length > 0) {
            return predicted; // already deployed
        }

        account = address(new SessionAccount{salt: bytes32(salt)}(entryPoint, owner));
        emit AccountCreated(account, owner, salt);
    }

    function getAddress(address owner, uint256 salt) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(SessionAccount).creationCode, abi.encode(entryPoint, owner));
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), keccak256(bytecode))))
            )
        );
    }
}
