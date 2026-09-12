pragma solidity ^0.8.24;

import {IPaymaster, UserOperation} from "./interfaces/IERC4337Minimal.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

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

    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        (uint48 validUntil, bytes memory sig) = _decodePaymasterData(userOp.paymasterAndData);

        bytes32 approvalHash = keccak256(
            abi.encode(userOp.sender, userOp.nonce, maxCost, validUntil, block.chainid)
        );
        address signer = MessageHashUtils.toEthSignedMessageHash(approvalHash).recover(sig);

        if (signer != trustedSigner) revert InvalidSponsorSignature();

        validationData = uint256(validUntil) << 160;
        context = abi.encode(userOp.sender);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external override onlyEntryPoint {
        if (mode == PostOpMode.postOpReverted) return;

        address account = abi.decode(context, (address));

        bool ok = IERC20(usdc).transferFrom(account, address(this), actualGasCost);
        if (!ok) revert ReimbursementFailed();

        emit Sponsored(account, actualGasCost);
    }

    function setTrustedSigner(address newSigner) external onlyOwner {
        trustedSigner = newSigner;
    }

    function _decodePaymasterData(bytes calldata data) internal pure returns (uint48 validUntil, bytes memory sig) {
        validUntil = uint48(bytes6(data[20:26]));
        sig = data[26:];
    }
}