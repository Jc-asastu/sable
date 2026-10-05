// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SableAccount} from "../../src/SableAccount.sol";

/// @dev Independent client-side encoding for the v3 wire format. Keys are mock test fixtures only.
abstract contract AgentOrders is Test {
    string internal orderDomainVersion = "5";
    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "SwapOrder(address router,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch,bytes32 dataHash)"
    );
    bytes32 private constant WITHDRAW_TYPEHASH = keccak256(
        "WithdrawOrder(address token,uint256 amount,address to,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch)"
    );

    function _signSwap(address account, uint256 key, SableAccount.SwapOrder memory o, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                o.router,
                o.tokenIn,
                o.amountIn,
                o.tokenOut,
                o.minOut,
                o.gasFee,
                o.nonce,
                o.deadline,
                o.epoch,
                keccak256(data)
            )
        );
        return _signOrder(account, key, structHash);
    }

    function _signWithdrawal(address account, uint256 key, SableAccount.WithdrawOrder memory o)
        internal
        view
        returns (bytes memory)
    {
        return _signOrder(
            account,
            key,
            keccak256(abi.encode(WITHDRAW_TYPEHASH, o.token, o.amount, o.to, o.gasFee, o.nonce, o.deadline, o.epoch))
        );
    }

    function _signOrder(address account, uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SableAccount"),
                keccak256(bytes(orderDomainVersion)),
                block.chainid,
                account
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
