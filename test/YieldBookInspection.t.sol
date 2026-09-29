// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {YieldBook} from "../src/YieldBook.sol";
import {MockToken, MockVault} from "./mocks/Mocks.sol";

contract YieldBookInspectionHarness is YieldBook {
    constructor(MockToken base_, MockToken quote_, MockVault vault_)
        YieldBook(base_, quote_, vault_, 18, 1, 1e18, 1_500)
    {}

    function head(bool bid, uint24 tick) external view returns (uint256) {
        return bid ? bidLevels[tick].head : askLevels[tick].head;
    }
}

contract YieldBookInspectionTest is Test {
    MockToken base;
    MockToken quote;
    MockVault vault;
    YieldBookInspectionHarness book;
    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address second = address(0xCA201);
    address[] actors;
    uint128 constant LOT = 1e18;
    uint24 constant TICK = 30_000;

    function setUp() public {
        base = new MockToken("BASE", 18);
        quote = new MockToken("QUOTE", 6);
        vault = new MockVault(quote);
        book = new YieldBookInspectionHarness(base, quote, vault);
    }

    function fund(address actor, uint256 cash, uint256 lots) internal {
        actors.push(actor);
        vm.startPrank(actor);
        if (cash != 0) {
            quote.mint(actor, cash);
            quote.approve(address(book), cash);
            book.depositQuote(cash);
        }
        if (lots != 0) {
            base.mint(actor, lots * LOT);
            base.approve(address(book), lots * LOT);
            book.depositBase(lots * LOT);
        }
        vm.stopPrank();
    }

    function place(address actor, bool bid, uint24 tick, uint128 size, bool ioc)
        internal
        returns (uint256 id, uint128 filled)
    {
        vm.prank(actor);
        return book.placeOrder(bid, tick, size, ioc);
    }

    function conserved() internal view {
        uint256 shares;
        uint256 bases;
        for (uint256 i; i < actors.length; i++) {
            shares += book.sharesOf(actors[i]);
            bases += book.baseOf(actors[i]);
        }
        for (uint256 id = 1; id < book.nextOrderId(); id++) {
            (, bool bid,,, uint256 locked) = book.orders(id);
            if (bid) shares += locked;
            else bases += locked;
        }
        assertEq(shares, book.totalShares());
        assertEq(bases, base.balanceOf(address(book)));
        if (book.bestBidTick() != 0 && book.bestAskTick() != 0) assertLt(book.bestBidTick(), book.bestAskTick());
    }

    function cancelledPrefix(bool makerBid, uint256 count) internal returns (uint256 live) {
        fund(maker, 100e6, count + 2);
        fund(taker, 100e6, 100);
        for (uint256 i; i < count + 2; i++) {
            place(maker, makerBid, TICK, LOT, false);
        }
        for (uint256 id = 1; id <= count; id++) {
            vm.prank(maker);
            book.cancel(id);
        }
        return count + 1;
    }

    function test_cancelledAskPrefixIsBoundedAndResumes() public {
        cancelledProgress(false);
    }

    function test_cancelledBidPrefixIsBoundedAndResumes() public {
        cancelledProgress(true);
    }

    function cancelledProgress(bool makerBid) internal {
        uint256 live = cancelledPrefix(makerBid, 65);
        uint256 shares = book.sharesOf(taker);
        uint256 bases = book.baseOf(taker);
        (uint256 id, uint128 filled) = place(taker, !makerBid, TICK, LOT, false);
        assertEq(id, 0, "never rest across unvisited liquidity");
        assertEq(filled, 0, "64 tombstones consume this call");
        assertEq(book.head(makerBid, TICK), 64);
        assertEq(book.sharesOf(taker), shares);
        assertEq(book.baseOf(taker), bases);
        (id, filled) = place(taker, !makerBid, TICK, LOT, false);
        assertEq(id, 0);
        assertEq(filled, LOT);
        (address firstOwner,,,,) = book.orders(live);
        (address nextOwner,,,,) = book.orders(live + 1);
        assertEq(firstOwner, address(0), "FIFO first live order fills");
        assertEq(nextOwner, maker);
        conserved();
    }

    function test_underfundedBidClosuresConsumeBudgetAndRefund() public {
        uint256[] memory refunded = new uint256[](65);
        for (uint256 i; i < 65; i++) {
            address actor = address(uint160(100 + i));
            fund(actor, TICK, 0);
            place(actor, true, TICK, LOT, false);
            (,,,, uint256 locked) = book.orders(i + 1);
            refunded[i] = book.sharesOf(actor) + locked;
        }
        fund(taker, 0, 2);
        uint256 assets = quote.balanceOf(address(vault));
        vm.prank(address(vault));
        quote.transfer(address(0xDEAD), assets / 2); // Real mock-vault asset loss, not unavailable liquidity.
        (uint256 id, uint128 filled) = place(taker, false, TICK, LOT, false);
        assertEq(id, 0);
        assertEq(filled, 0);
        assertEq(book.head(true, TICK), 64);
        for (uint256 i; i < 64; i++) {
            (address owner,,,,) = book.orders(i + 1);
            assertEq(owner, address(0));
            assertEq(book.sharesOf(actors[i]), refunded[i], "closed bids return exactly their locked shares");
        }
        (address remaining,,,,) = book.orders(65);
        assertEq(remaining, actors[64]);
        conserved();
        (id, filled) = place(taker, false, TICK, LOT, false);
        assertGt(id, 0, "can rest after last crossing bid is closed");
        assertEq(filled, 0);
        assertEq(book.bestBidTick(), 0);
        assertEq(book.head(true, TICK), 65);
        assertEq(book.sharesOf(actors[64]), refunded[64]);
        conserved();
    }

    function test_mixedAskHeadsShareBudgetAcrossPrices() public {
        mixedLevels(false);
    }

    function test_mixedBidHeadsShareBudgetAcrossPrices() public {
        mixedLevels(true);
    }

    function mixedLevels(bool makerBid) internal {
        fund(maker, 100e6, 100);
        fund(second, 100e6, 100);
        fund(taker, 100e6, 100);
        uint24 best = makerBid ? TICK + 1 : TICK - 1;
        for (uint256 i; i < 63; i++) {
            place(maker, makerBid, best, LOT, false);
        }
        place(second, makerBid, TICK, LOT, false);
        place(maker, makerBid, TICK, 2 * LOT, false);
        for (uint256 id = 1; id <= 62; id++) {
            vm.prank(maker);
            book.cancel(id);
        }
        uint256 beforeQuote = book.quoteBalanceOf(taker);
        (uint256 resting, uint128 filled) = place(taker, !makerBid, TICK, 4 * LOT, false);
        assertEq(filled, 2 * LOT, "62 skips and two fills share one budget across prices");
        assertEq(resting, 0, "do not cross the remaining maker");
        uint256 afterQuote = book.quoteBalanceOf(taker);
        assertApproxEqAbs(makerBid ? afterQuote - beforeQuote : beforeQuote - afterQuote, uint256(best) + TICK, 3);
        assertEq(book.head(makerBid, best), 63);
        assertEq(book.head(makerBid, TICK), 1);
        (address earlier,,,,) = book.orders(64);
        (address later,,,,) = book.orders(65);
        assertEq(earlier, address(0), "earlier same-price maker filled first");
        assertEq(later, maker);
        conserved();

        vault.accrue(100e6); // Next call must use the fresh share price, not the previous call's.
        beforeQuote = book.quoteBalanceOf(taker);
        (resting, filled) = place(taker, !makerBid, TICK, 2 * LOT, false);
        afterQuote = book.quoteBalanceOf(taker);
        assertEq(filled, 2 * LOT);
        assertEq(resting, 0);
        assertApproxEqAbs(makerBid ? afterQuote - beforeQuote : beforeQuote - afterQuote, 2 * TICK, 3);
        assertEq(makerBid ? book.bestBidTick() : book.bestAskTick(), 0);
        conserved();
    }

    function test_exactAskInspectionBoundary() public {
        exactBoundary(false);
    }

    function test_exactBidInspectionBoundary() public {
        exactBoundary(true);
    }

    function exactBoundary(bool makerBid) internal {
        cancelledPrefix(makerBid, 63);
        (uint256 id, uint128 filled) = place(taker, !makerBid, TICK, 2 * LOT, true);
        assertEq(id, 0);
        assertEq(filled, LOT, "the 64th inspected head may fill, the 65th cannot");
        assertEq(book.head(makerBid, TICK), 64);
        conserved();
        (id, filled) = place(taker, !makerBid, TICK, 2 * LOT, false);
        assertEq(filled, LOT);
        assertGt(id, 0, "rest only after all crossing liquidity is gone");
        conserved();
    }

    function test_cleanBookRetains64FillsOnBothSides() public {
        for (uint256 side; side < 2; side++) {
            setUp();
            delete actors;
            fund(maker, 100e6, 100);
            fund(taker, 100e6, 100);
            bool makerBid = side == 1;
            for (uint256 i; i < 65; i++) {
                place(maker, makerBid, TICK, LOT, false);
            }
            (uint256 id, uint128 filled) = place(taker, !makerBid, TICK, 65 * LOT, false);
            assertEq(filled, 64 * LOT);
            assertEq(id, 0);
            assertEq(book.head(makerBid, TICK), 64);
            conserved();
        }
    }

    function test_budgetEndingOnLastLiveHeadAllowsResting() public {
        for (uint256 side; side < 2; side++) {
            setUp();
            delete actors;
            bool makerBid = side == 1;
            cancelledPrefix(makerBid, 63);
            vm.prank(maker);
            book.cancel(65); // Leave only the 64th head live.
            (uint256 id, uint128 filled) = place(taker, !makerBid, TICK, 2 * LOT, false);
            assertEq(filled, LOT);
            assertGt(id, 0, "budget exhaustion alone must not prevent a noncrossing remainder");
            assertEq(makerBid ? book.bestBidTick() : book.bestAskTick(), 0);
            conserved();
        }
    }
}
