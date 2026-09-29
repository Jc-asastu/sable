// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickBitmap} from "./TickBitmap.sol";

/// @title YieldBook (spike)
/// @notice Single-pair central limit order book on internal balances. Every quote balance,
/// free or locked in a resting bid, is a share of one pool worth `cash + vault assets`, so it
/// earns the lending vault's yield until it is used. Fills only move pool shares between
/// accounts: matching never calls the vault and cannot fail on vault liquidity (DECISIONS D1).
contract YieldBook is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TickBitmap for TickBitmap.Bitmap;

    IERC20 public immutable base;
    IERC20 public immutable quote;
    IERC4626 public immutable vault;
    uint256 public immutable baseScale; // 10 ** base decimals
    uint256 public immutable tickSize; // quote units per whole base token, per tick
    uint256 public immutable lotSize; // base units
    uint256 public immutable bufferBps; // share of pool assets kept as cash

    uint256 public constant MAX_FILLS = 64;
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    // quote pool
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    // base balances (no yield in v0, DECISIONS D4)
    mapping(address => uint256) public baseOf;

    struct Order {
        address owner;
        bool isBid;
        uint24 tick;
        uint128 size; // base units still open
        uint256 locked; // pool shares for bids, base units for asks
    }

    struct Level {
        uint256[] ids;
        uint256 head;
        uint256 live;
    }

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;
    mapping(uint24 => Level) internal bidLevels;
    mapping(uint24 => Level) internal askLevels;
    TickBitmap.Bitmap internal bidTicks;
    TickBitmap.Bitmap internal askTicks;
    // cached best prices, 0 = empty side; the bitmap is searched only when a best level empties
    uint24 public bestBidTick;
    uint24 public bestAskTick;
    // live price levels per side, so emptying a side never scans the bitmap
    uint256 public bidLevelCount;
    uint256 public askLevelCount;

    event Deposit(address indexed user, bool isQuote, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, bool isQuote, uint256 amount, uint256 shares);
    event OrderPlaced(uint256 indexed id, address indexed owner, bool isBid, uint24 tick, uint128 size);
    event OrderClosed(uint256 indexed id, uint256 refunded);
    event Fill(uint256 indexed makerId, address indexed taker, uint24 tick, uint128 size, uint256 value);

    error BadParams();
    error ZeroAmount();
    error BadSize();
    error BadTick();
    error NotOwner();
    error InsufficientBalance();
    error InsufficientLiquidity(uint256 available);

    constructor(
        IERC20 base_,
        IERC20 quote_,
        IERC4626 vault_,
        uint8 baseDecimals,
        uint256 tickSize_,
        uint256 lotSize_,
        uint256 bufferBps_
    ) {
        uint256 scale = 10 ** baseDecimals;
        if (
            vault_.asset() != address(quote_) || tickSize_ == 0 || lotSize_ == 0 || bufferBps_ > 10_000
                || (lotSize_ * tickSize_) % scale != 0
        ) revert BadParams();
        base = base_;
        quote = quote_;
        vault = vault_;
        baseScale = scale;
        tickSize = tickSize_;
        lotSize = lotSize_;
        bufferBps = bufferBps_;
    }

    // ───────────────────────── pool accounting ─────────────────────────

    function totalAssets() public view returns (uint256) {
        return quote.balanceOf(address(this)) + vault.convertToAssets(vault.balanceOf(address(this)));
    }

    function quoteBalanceOf(address user) external view returns (uint256) {
        return _toAssets(sharesOf[user], totalAssets(), totalShares, Math.Rounding.Floor);
    }

    function _toShares(uint256 assets, uint256 ta, uint256 ts, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(assets, ts + VIRTUAL_SHARES, ta + VIRTUAL_ASSETS, r);
    }

    function _toAssets(uint256 shares, uint256 ta, uint256 ts, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(shares, ta + VIRTUAL_ASSETS, ts + VIRTUAL_SHARES, r);
    }

    // ───────────────────────── deposits ─────────────────────────

    function depositQuote(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        uint256 shares = _toShares(assets, totalAssets(), totalShares, Math.Rounding.Floor);
        quote.safeTransferFrom(msg.sender, address(this), assets);
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        _rebalance();
        emit Deposit(msg.sender, true, assets, shares);
    }

    /// @notice Served from the cash buffer first, then from the vault. Reverts with the
    /// currently available amount when the vault cannot pay the rest.
    function withdrawQuote(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        uint256 shares = _toShares(assets, totalAssets(), totalShares, Math.Rounding.Ceil);
        if (shares > sharesOf[msg.sender]) revert InsufficientBalance();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        uint256 cash = quote.balanceOf(address(this));
        if (cash < assets) {
            uint256 need = assets - cash;
            uint256 maxOut = vault.maxWithdraw(address(this));
            if (need > maxOut) revert InsufficientLiquidity(cash + maxOut);
            vault.withdraw(need, address(this), address(this));
        }
        quote.safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, true, assets, shares);
    }

    function depositBase(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        base.safeTransferFrom(msg.sender, address(this), amount);
        baseOf[msg.sender] += amount;
        emit Deposit(msg.sender, false, amount, 0);
    }

    function withdrawBase(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > baseOf[msg.sender]) revert InsufficientBalance();
        baseOf[msg.sender] -= amount;
        base.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, false, amount, 0);
    }

    /// @notice Moves cash toward `bufferBps` of pool assets. Anyone can call it.
    function rebalance() external nonReentrant {
        _rebalance();
    }

    function _rebalance() internal {
        uint256 cash = quote.balanceOf(address(this));
        uint256 target = totalAssets() * bufferBps / 10_000;
        if (cash > target) {
            uint256 excess = Math.min(cash - target, vault.maxDeposit(address(this)));
            if (excess == 0) return;
            quote.forceApprove(address(vault), excess);
            vault.deposit(excess, address(this));
        } else if (cash < target) {
            uint256 short = Math.min(target - cash, vault.maxWithdraw(address(this)));
            if (short > 0) vault.withdraw(short, address(this), address(this));
        }
    }

    // ───────────────────────── orders ─────────────────────────

    function price(uint24 tick) public view returns (uint256) {
        return uint256(tick) * tickSize;
    }

    function bestBid() external view returns (bool, uint24) {
        return (bestBidTick != 0, bestBidTick);
    }

    function bestAsk() external view returns (bool, uint24) {
        return (bestAskTick != 0, bestAskTick);
    }

    /// @notice Limit order against internal balances. Matches at maker prices, then rests the
    /// remainder unless `ioc`. A market order is a limit at the extreme tick with `ioc`.
    /// @return id resting order id (0 if nothing rests)
    /// @return filled base units filled as taker
    function placeOrder(bool isBid, uint24 tick, uint128 size, bool ioc)
        external
        nonReentrant
        returns (uint256 id, uint128 filled)
    {
        if (tick == 0) revert BadTick();
        if (size == 0 || size % lotSize != 0) revert BadSize();
        // Matching only moves shares between accounts, so the share price is fixed for this call.
        // Fresh read every call: a cached share price leaks value between maker and taker when
        // the pool value moves inside a block (DECISIONS D8).
        uint256 ta = totalAssets();
        uint256 ts = totalShares;

        bool crossedLeft;
        (filled, crossedLeft) = isBid ? _buy(tick, size, ta, ts) : _sell(tick, size, ta, ts);
        uint128 remaining = size - filled;
        // If the fill cap stopped us while the book still crosses, resting would cross it.
        if (remaining == 0 || ioc || crossedLeft) return (0, filled);

        id = nextOrderId++;
        uint256 locked;
        if (isBid) {
            locked = _toShares(uint256(remaining) * price(tick) / baseScale, ta, ts, Math.Rounding.Ceil);
            if (locked > sharesOf[msg.sender]) revert InsufficientBalance();
            sharesOf[msg.sender] -= locked;
            if (_push(bidLevels[tick], bidTicks, tick, id)) bidLevelCount++;
            if (tick > bestBidTick) bestBidTick = tick;
        } else {
            locked = remaining;
            if (locked > baseOf[msg.sender]) revert InsufficientBalance();
            baseOf[msg.sender] -= locked;
            if (_push(askLevels[tick], askTicks, tick, id)) askLevelCount++;
            if (bestAskTick == 0 || tick < bestAskTick) bestAskTick = tick;
        }
        orders[id] = Order(msg.sender, isBid, tick, remaining, locked);
        emit OrderPlaced(id, msg.sender, isBid, tick, remaining);
    }

    function cancel(uint256 id) external nonReentrant {
        Order memory o = orders[id];
        if (o.owner != msg.sender) revert NotOwner();
        if (o.isBid) {
            sharesOf[o.owner] += o.locked; // includes the yield earned while resting
            _drop(bidLevels[o.tick], true, o.tick);
        } else {
            baseOf[o.owner] += o.locked;
            _drop(askLevels[o.tick], false, o.tick);
        }
        delete orders[id];
        emit OrderClosed(id, o.locked);
    }

    /// taker buys base, pays quote shares to ask makers
    function _buy(uint24 limit, uint128 size, uint256 ta, uint256 ts)
        internal
        returns (uint128 filled, bool crossedLeft)
    {
        uint256 fills;
        while (filled < size) {
            uint24 t = bestAskTick;
            if (t == 0 || t > limit) return (filled, false);
            if (fills == MAX_FILLS) return (filled, true);
            Level storage L = askLevels[t];
            uint256 p = price(t);
            while (filled < size && L.live > 0 && fills < MAX_FILLS) {
                uint256 oid = L.ids[L.head];
                Order storage o = orders[oid];
                if (o.size == 0) {
                    L.head++;
                    continue;
                }
                uint128 q = size - filled < o.size ? size - filled : o.size;
                uint256 value = uint256(q) * p / baseScale;
                uint256 s = _toShares(value, ta, ts, Math.Rounding.Ceil);
                if (s > sharesOf[msg.sender]) revert InsufficientBalance();
                sharesOf[msg.sender] -= s;
                sharesOf[o.owner] += s;
                baseOf[msg.sender] += q;
                o.size -= q;
                o.locked -= q;
                filled += q;
                fills++;
                emit Fill(oid, msg.sender, t, q, value);
                if (o.size == 0) _close(L, false, t, oid, 0);
            }
        }
    }

    /// taker sells base, receives quote shares from bid makers
    function _sell(uint24 limit, uint128 size, uint256 ta, uint256 ts)
        internal
        returns (uint128 filled, bool crossedLeft)
    {
        uint256 fills;
        while (filled < size) {
            uint24 t = bestBidTick;
            if (t == 0 || t < limit) return (filled, false);
            if (fills == MAX_FILLS) return (filled, true);
            Level storage L = bidLevels[t];
            uint256 p = price(t);
            while (filled < size && L.live > 0 && fills < MAX_FILLS) {
                uint256 oid = L.ids[L.head];
                Order storage o = orders[oid];
                if (o.size == 0) {
                    L.head++;
                    continue;
                }
                uint128 q = size - filled < o.size ? size - filled : o.size;
                uint256 value = uint256(q) * p / baseScale;
                uint256 s = _toShares(value, ta, ts, Math.Rounding.Ceil);
                if (q > baseOf[msg.sender]) revert InsufficientBalance();
                if (s > o.locked) {
                    // Pool lost value since the bid was placed; top up from the maker's free
                    // shares, or close the bid if they cannot cover it.
                    uint256 gap = s - o.locked;
                    if (gap > sharesOf[o.owner]) {
                        sharesOf[o.owner] += o.locked;
                        emit OrderClosed(oid, o.locked);
                        _close(L, true, t, oid, 0);
                        continue;
                    }
                    sharesOf[o.owner] -= gap;
                    o.locked += gap;
                }
                baseOf[msg.sender] -= q;
                baseOf[o.owner] += q;
                o.locked -= s;
                sharesOf[msg.sender] += s;
                o.size -= q;
                filled += q;
                fills++;
                emit Fill(oid, msg.sender, t, q, value);
                if (o.size == 0) {
                    // leftover shares are the yield the bid earned while resting
                    sharesOf[o.owner] += o.locked;
                    _close(L, true, t, oid, o.locked);
                }
            }
        }
    }

    /// @return opened true when this order opened a new price level
    function _push(Level storage L, TickBitmap.Bitmap storage bm, uint24 t, uint256 id) internal returns (bool opened) {
        L.ids.push(id);
        opened = L.live++ == 0;
        if (opened) bm.set(t);
    }

    function _drop(Level storage L, bool isBid, uint24 t) internal {
        if (--L.live > 0) return;
        L.head = L.ids.length;
        if (isBid) {
            bidTicks.clear(t);
            if (--bidLevelCount == 0) bestBidTick = 0;
            else if (t == bestBidTick) (, bestBidTick) = bidTicks.atOrBelow(t);
        } else {
            askTicks.clear(t);
            if (--askLevelCount == 0) bestAskTick = 0;
            else if (t == bestAskTick) (, bestAskTick) = askTicks.atOrAbove(t);
        }
    }

    function _close(Level storage L, bool isBid, uint24 t, uint256 oid, uint256 refunded) internal {
        L.head++;
        delete orders[oid];
        _drop(L, isBid, t);
        if (refunded > 0) emit OrderClosed(oid, refunded);
    }
}
