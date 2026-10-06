// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {YieldBook} from "../src/YieldBook.sol";
import {MockToken, MockVault} from "./mocks/Mocks.sol";

contract Handler is Test {
    YieldBook book;
    MockToken mon;
    MockToken usdc;
    MockVault vault;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];

    constructor(YieldBook b, MockToken m, MockToken u, MockVault v) {
        book = b;
        mon = m;
        usdc = u;
        vault = v;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function depositQuote(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1e6, 1_000_000e6);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(book), amt);
        book.depositQuote(amt);
        vm.stopPrank();
    }

    function depositBase(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, 1_000_000) * 1e18;
        mon.mint(a, amt);
        vm.startPrank(a);
        mon.approve(address(book), amt);
        book.depositBase(amt);
        vm.stopPrank();
    }

    function place(uint256 seed, bool isBid, uint256 tick, uint256 lots, bool ioc) external {
        tick = bound(tick, 29_000, 29_500); // narrow band so orders cross often
        lots = bound(lots, 1, 50_000);
        vm.prank(_actor(seed));
        book.placeOrder(isBid, uint24(tick), uint128(lots * 1e18), ioc);
    }

    function cancel(uint256 seed, uint256 id) external {
        uint256 n = book.nextOrderId();
        if (n == 1) return;
        id = bound(id, 1, n - 1);
        (address owner,,,,) = book.orders(id);
        if (owner == address(0)) return;
        vm.prank(owner);
        book.cancel(id);
        seed;
    }

    function accrue(uint256 amt) external {
        vault.accrue(bound(amt, 0, 10_000e6));
    }

    function withdrawQuote(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        uint256 bal = book.quoteBalanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        book.withdrawQuote(bound(amt, 1, bal));
    }

    function setLiquidity(uint256 a) external {
        vault.setAvailable(bound(a, 0, 2_000_000e6));
    }

    function rebalance() external {
        book.rebalance();
    }
}

contract YieldBookInvariantTest is Test {
    YieldBook book;
    MockToken mon;
    MockToken usdc;
    MockVault vault;
    Handler handler;

    function setUp() public {
        mon = new MockToken("MON", 18);
        usdc = new MockToken("USDC", 6);
        vault = new MockVault(usdc);
        book = new YieldBook(mon, usdc, vault, 18, 1, 1e18, 1_500);
        handler = new Handler(book, mon, usdc, vault);
        targetContract(address(handler));
    }

    /// every pool share is owned by a user balance or a resting bid
    function invariant_sharesConserved() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            sum += book.sharesOf(handler.actors(i));
        }
        for (uint256 id = 1; id < book.nextOrderId(); id++) {
            (, bool isBid,,, uint256 locked) = book.orders(id);
            if (isBid) sum += locked;
        }
        assertEq(sum, book.totalShares());
    }

    /// base held by the book equals free base plus base locked in asks
    function invariant_baseConserved() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            sum += book.baseOf(handler.actors(i));
        }
        for (uint256 id = 1; id < book.nextOrderId(); id++) {
            (, bool isBid,,, uint256 locked) = book.orders(id);
            if (!isBid) sum += locked;
        }
        assertEq(sum, mon.balanceOf(address(book)));
    }

    /// resting orders never cross
    function invariant_bookNeverCrossed() public view {
        uint24 bid = book.bestBidTick();
        uint24 ask = book.bestAskTick();
        if (bid != 0 && ask != 0) assertLt(bid, ask);
    }

    /// the cached best prices match live orders on the book
    function invariant_bestPricesAreLive() public view {
        uint24 bestBid;
        uint24 bestAsk = type(uint24).max;
        for (uint256 id = 1; id < book.nextOrderId(); id++) {
            (address owner, bool isBid, uint24 tick,,) = book.orders(id);
            if (owner == address(0)) continue;
            if (isBid && tick > bestBid) bestBid = tick;
            if (!isBid && tick < bestAsk) bestAsk = tick;
        }
        assertEq(book.bestBidTick(), bestBid);
        assertEq(book.bestAskTick(), bestAsk == type(uint24).max ? 0 : bestAsk);
    }
}
