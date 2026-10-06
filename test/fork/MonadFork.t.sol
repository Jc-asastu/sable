// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {YieldBook} from "../../src/YieldBook.sol";
import {MockToken} from "../mocks/Mocks.sol";

/// @notice Runs against Monad mainnet state with a real Morpho USDC vault.
/// Skipped unless MONAD_RPC_URL is set:  MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc MonadFork -vv
contract MonadForkTest is Test {
    // Addresses from the Morpho API (chain 143), checked on-chain by test_addressesAreWhatWeThink.
    IERC20 constant USDC = IERC20(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
    IERC4626 constant VAULT = IERC4626(0x802c91d807A8DaCA257c4708ab264B6520964e44); // Steakhouse High Yield USDC

    YieldBook book;
    MockToken mon;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        mon = new MockToken("MON", 18);
        book = new YieldBook(mon, USDC, VAULT, 18, 1, 1e18, 1_500);
    }

    function test_addressesAreWhatWeThink() public view {
        assertEq(block.chainid, 143, "Monad mainnet");
        assertEq(VAULT.asset(), address(USDC), "vault asset is USDC");
        (bool ok, bytes memory d) = address(USDC).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(abi.decode(d, (uint8)), 6);
    }

    function test_realVaultEarnsAndPaysBack() public {
        deal(address(USDC), alice, 10_000e6);
        vm.startPrank(alice);
        USDC.approve(address(book), 10_000e6);
        book.depositQuote(10_000e6);
        vm.stopPrank();
        assertGt(VAULT.balanceOf(address(book)), 0, "deposited into the real vault");

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_000_000);
        uint256 bal = book.quoteBalanceOf(alice);
        console2.log("alice after 30 days (USDC units)", bal);
        assertGe(bal, 10_000e6 - 2, "no loss beyond rounding");

        vm.prank(alice);
        book.withdrawQuote(bal < 10_000e6 ? bal : 10_000e6);
    }

    function test_fillAgainstRealVaultPool() public {
        deal(address(USDC), alice, 3_000e6);
        vm.startPrank(alice);
        USDC.approve(address(book), 3_000e6);
        book.depositQuote(3_000e6);
        book.placeOrder(true, 29_250, 100_000e18, false);
        vm.stopPrank();

        mon.mint(bob, 100_000e18);
        vm.startPrank(bob);
        mon.approve(address(book), 100_000e18);
        book.depositBase(100_000e18);
        uint256 g = gasleft();
        (, uint128 filled) = book.placeOrder(false, 29_250, 100_000e18, true);
        console2.log("gas: fill on Monad fork", g - gasleft());
        vm.stopPrank();
        assertEq(filled, 100_000e18);
        assertApproxEqAbs(book.quoteBalanceOf(bob), 2_925e6, 2);
    }
}
