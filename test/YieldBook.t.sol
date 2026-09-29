// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {YieldBook} from "../src/YieldBook.sol";
import {MockToken, MockVault} from "./mocks/Mocks.sol";

contract YieldBookTest is Test {
    MockToken mon; // base, 18 decimals
    MockToken usdc; // quote, 6 decimals
    MockVault vault;
    YieldBook book;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint128 constant MON = 1e18;
    uint24 constant T = 29_250; // 0.029250 USDC per MON

    function setUp() public {
        mon = new MockToken("MON", 18);
        usdc = new MockToken("USDC", 6);
        vault = new MockVault(usdc);
        // tickSize 1 = 0.000001 USDC per MON, lot 1 MON, 15% cash buffer
        book = new YieldBook(mon, usdc, vault, 18, 1, MON, 1_500);
    }

    function _fund(address u, uint256 q, uint256 b) internal {
        vm.startPrank(u);
        if (q > 0) {
            usdc.mint(u, q);
            usdc.approve(address(book), q);
            book.depositQuote(q);
        }
        if (b > 0) {
            mon.mint(u, b);
            mon.approve(address(book), b);
            book.depositBase(b);
        }
        vm.stopPrank();
    }

    // ── pool ──

    function test_depositSplitsIntoBufferAndVault() public {
        _fund(alice, 10_000e6, 0);
        assertEq(usdc.balanceOf(address(book)), 1_500e6, "15% stays as cash");
        assertEq(vault.convertToAssets(vault.balanceOf(address(book))), 8_500e6, "85% earns in the vault");
    }

    function test_idleBalanceEarnsYield() public {
        _fund(alice, 10_000e6, 0);
        vault.accrue(85e6); // +1% on the vault position
        assertApproxEqAbs(book.quoteBalanceOf(alice), 10_085e6, 2);
    }

    function test_yieldSplitsProRata() public {
        _fund(alice, 10_000e6, 0);
        _fund(bob, 30_000e6, 0);
        vault.accrue(340e6);
        assertApproxEqAbs(book.quoteBalanceOf(alice), 10_085e6, 3);
        assertApproxEqAbs(book.quoteBalanceOf(bob), 30_255e6, 3);
    }

    // ── the core claim: resting bids earn until they fill ──

    function test_restingBidEarnsYieldThenFills() public {
        _fund(alice, 3_000e6, 0);
        vm.prank(alice);
        (uint256 id,) = book.placeOrder(true, T, 100_000 * MON, false); // locks 2,925 USDC
        assertGt(id, 0);

        vault.accrue(50e6); // the whole pool is alice's, so the whole yield is hers

        _fund(bob, 0, 100_000 * MON);
        vm.prank(bob);
        (, uint128 filled) = book.placeOrder(false, T, 100_000 * MON, true);

        assertEq(filled, 100_000 * MON);
        assertEq(book.baseOf(alice), 100_000 * MON, "maker got the base");
        assertApproxEqAbs(book.quoteBalanceOf(bob), 2_925e6, 1, "taker got exactly the bid value");
        // 3,000 - 2,925 = 75 left, plus the 50 of yield earned while resting
        assertApproxEqAbs(book.quoteBalanceOf(alice), 125e6, 2, "maker kept the yield");
    }

    function test_cancelReturnsPrincipalPlusYield() public {
        _fund(alice, 3_000e6, 0);
        vm.prank(alice);
        (uint256 id,) = book.placeOrder(true, T, 100_000 * MON, false);
        vault.accrue(50e6);
        vm.prank(alice);
        book.cancel(id);
        assertApproxEqAbs(book.quoteBalanceOf(alice), 3_050e6, 2);
    }

    // ── liquidity risk lives in withdrawals, never in matching ──

    function test_fillsNeverTouchTheVault() public {
        _fund(alice, 3_000e6, 0);
        vm.prank(alice);
        book.placeOrder(true, T, 100_000 * MON, false);
        vault.setAvailable(0); // lending market 100% utilized
        uint256 vaultSharesBefore = vault.balanceOf(address(book));

        _fund(bob, 0, 100_000 * MON);
        vm.prank(bob);
        (, uint128 filled) = book.placeOrder(false, T, 100_000 * MON, true);

        assertEq(filled, 100_000 * MON, "fill succeeded with an illiquid vault");
        assertEq(vault.balanceOf(address(book)), vaultSharesBefore, "vault untouched");
    }

    function test_withdrawDegradesCleanlyWhenVaultIlliquid() public {
        _fund(alice, 10_000e6, 0);
        vault.setAvailable(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YieldBook.InsufficientLiquidity.selector, 1_500e6));
        book.withdrawQuote(2_000e6);
        vm.prank(alice);
        book.withdrawQuote(1_000e6); // the cash buffer still serves it
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    function test_withdrawPullsFromVaultWhenBufferShort() public {
        _fund(alice, 10_000e6, 0);
        vm.prank(alice);
        book.withdrawQuote(4_000e6);
        assertEq(usdc.balanceOf(alice), 4_000e6);
        book.rebalance();
        assertApproxEqAbs(usdc.balanceOf(address(book)), 900e6, 1, "buffer restored to 15% of 6,000");
    }

    // ── matching ──

    function test_priceTimePriority() public {
        _fund(alice, 3_000e6, 0);
        _fund(carol, 3_000e6, 0);
        vm.prank(alice);
        book.placeOrder(true, T, 10 * MON, false);
        vm.prank(carol);
        book.placeOrder(true, T, 10 * MON, false);

        _fund(bob, 0, 15 * MON);
        vm.prank(bob);
        book.placeOrder(false, T, 15 * MON, true);

        assertEq(book.baseOf(alice), 10 * MON, "first in line filled fully");
        assertEq(book.baseOf(carol), 5 * MON, "second filled partially");
    }

    function test_takerWalksAsksBestPriceFirstAtMakerPrices() public {
        _fund(bob, 0, 30 * MON);
        vm.startPrank(bob);
        book.placeOrder(false, 30_000, 10 * MON, false);
        book.placeOrder(false, 29_000, 10 * MON, false);
        book.placeOrder(false, 31_000, 10 * MON, false);
        vm.stopPrank();

        _fund(alice, 1_000e6, 0);
        vm.prank(alice);
        (uint256 id, uint128 filled) = book.placeOrder(true, 30_500, 30 * MON, false);

        assertEq(filled, 20 * MON, "only asks at or under the limit");
        assertEq(book.baseOf(alice), 20 * MON);
        // paid 10*0.029 + 10*0.030 = 0.59 USDC at maker prices
        assertApproxEqAbs(book.quoteBalanceOf(bob), 590_000, 1);
        // the remaining 10 MON rests as a bid at 30,500
        (bool hasBid, uint24 bid) = book.bestBid();
        (bool hasAsk, uint24 ask) = book.bestAsk();
        assertTrue(hasBid && hasAsk && id > 0);
        assertEq(bid, 30_500);
        assertEq(ask, 31_000);
    }

    function test_bitmapFindsFarTicks() public {
        _fund(bob, 0, 2 * MON);
        vm.startPrank(bob);
        book.placeOrder(false, 16_000_000, MON, false);
        book.placeOrder(false, 3, MON, false);
        vm.stopPrank();
        (, uint24 ask) = book.bestAsk();
        assertEq(ask, 3);
    }

    function test_revertsOnBadSizeAndTick() public {
        vm.expectRevert(YieldBook.BadSize.selector);
        book.placeOrder(true, T, MON / 2, false);
        vm.expectRevert(YieldBook.BadTick.selector);
        book.placeOrder(true, 0, MON, false);
    }

    function test_cannotCancelOthersOrders() public {
        _fund(alice, 3_000e6, 0);
        vm.prank(alice);
        (uint256 id,) = book.placeOrder(true, T, MON, false);
        vm.prank(bob);
        vm.expectRevert(YieldBook.NotOwner.selector);
        book.cancel(id);
    }

    // ── gas: the kill criterion compares fill cost ──

    function test_gas_singleFill() public {
        _fund(alice, 3_000e6, 0);
        vm.prank(alice);
        book.placeOrder(true, T, 100_000 * MON, false);
        _fund(bob, 0, 100_000 * MON);
        vm.prank(bob);
        uint256 g = gasleft();
        book.placeOrder(false, T, 100_000 * MON, true);
        console2.log("gas: taker sell filling one resting bid", g - gasleft());
    }

    // ── fuzz ──

    function testFuzz_depositWithdrawNeverProfitsWithoutYield(uint96 amount) public {
        vm.assume(amount > 1e6);
        _fund(alice, amount, 0);
        uint256 bal = book.quoteBalanceOf(alice);
        assertLe(bal, amount, "rounding never favours the user");
        vm.prank(alice);
        book.withdrawQuote(bal);
        assertLe(usdc.balanceOf(alice), amount);
    }
}
