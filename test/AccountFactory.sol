pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {SessionAccount} from "../src/SessionAccount.sol";

contract AccountFactoryTest is Test {
    AccountFactory factory;
    address entryPoint = makeAddr("entryPoint");
    address user = makeAddr("user");

    function setUp() public {
        factory = new AccountFactory(entryPoint);
    }

    function test_getAddress_matchesActualDeployment() public {
        uint256 salt = 1;
        address predicted = factory.getAddress(user, salt);

        address deployed = factory.createAccount(user, salt);

        assertEq(predicted, deployed, "predicted address must match actual deployment");
        assertGt(deployed.code.length, 0, "account should have code after deployment");
    }

    function test_createAccount_isIdempotent() public {
        uint256 salt = 42;
        address first = factory.createAccount(user, salt);
        address second = factory.createAccount(user, salt);

        assertEq(first, second);
    }

    function test_differentSalts_produceDifferentAddresses() public {
        address a = factory.getAddress(user, 1);
        address b = factory.getAddress(user, 2);
        assertTrue(a != b);
    }

    function test_deployedAccount_hasCorrectOwnerAndEntryPoint() public {
        address deployed = factory.createAccount(user, 7);
        SessionAccount acct = SessionAccount(payable(deployed));

        assertEq(acct.owner(), user);
        assertEq(acct.entryPoint(), entryPoint);
    }
}