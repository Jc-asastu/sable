// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SableAccount, IWMON} from "../../src/SableAccount.sol";
import {SableAccountFactory} from "../../src/SableAccountFactory.sol";
import {TokenRegistry} from "../../src/TokenRegistry.sol";

/// @notice A cross-chain fill against the real Across SpokePool on Monad mainnet state: the hand-encoded
/// deposit is accepted and Across records the owner's recipient and the limit. Skipped unless
/// MONAD_RPC_URL is set: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc AcrossFork -vv
contract AcrossForkTest is Test {
    IERC20 constant USDC = IERC20(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
    IWMON constant WMON = IWMON(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);
    address constant SPOKE_POOL = 0xd2ecb3afe598b746F8123CaE365a598DA831A449;
    address constant AAVE_USDC = 0xC554aFfE2f581F5E0811e0D42D484ECaC5c6B8e2;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint64 constant BASE = 8453;

    function test_aCrossFillDepositsIntoAcrossWithTheOwnersRecipient() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertGt(SPOKE_POOL.code.length, 0, "Across SpokePool deployed on Monad");

        SableAccountFactory factory = new SableAccountFactory(address(this), WMON);
        TokenRegistry registry = factory.registry();
        registry.setVault(AAVE_USDC, true);
        registry.setKeeper(address(this), true);
        registry.setAcrossSpokePool(SPOKE_POOL);
        factory.openToEveryone();

        address owner = makeAddr("owner");
        vm.prank(owner);
        SableAccount account = SableAccount(payable(factory.createAccount(address(0), new address[](0), 0, 0)));
        deal(address(USDC), address(account), 100e6);

        SableAccount.Secret memory s;
        s.destChainId = BASE;
        s.destMinOut = 95e6; // at least 95 USDC on Base
        s.recipient = bytes32(uint256(uint160(owner)));
        s.destToken = bytes32(uint256(uint160(BASE_USDC)));
        s.salt = keccak256("fork");
        SableAccount.OrderParams memory p = SableAccount.OrderParams({
            tokenIn: address(USDC), vault: AAVE_USDC, deadline: uint64(block.timestamp + 1 days), amountIn: 100e6,
            commit: keccak256(abi.encode(s))
        });
        vm.prank(owner);
        uint256 id = account.placeOrder(p);

        uint256 poolBefore = USDC.balanceOf(SPOKE_POOL);
        vm.recordLogs();
        account.fillCrossOrder(id, s, 96e6, uint32(block.timestamp), 0);
        assertGt(USDC.balanceOf(SPOKE_POOL), poolBefore, "the SpokePool took the deposit");

        // Across' FundsDeposited event carries the recipient and output we built from the order.
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != SPOKE_POOL) continue;
            bytes memory data = logs[i].data;
            seen = seen || _contains(data, s.recipient);
        }
        assertTrue(seen, "Across recorded the owner's recipient");
    }

    function _contains(bytes memory data, bytes32 word) private pure returns (bool) {
        for (uint256 i; i + 32 <= data.length; i += 32) {
            bytes32 w;
            assembly { w := mload(add(add(data, 32), i)) }
            if (w == word) return true;
        }
        return false;
    }
}
