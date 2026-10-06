// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TokenRegistry} from "./TokenRegistry.sol";

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// Across' SpokePool (v3.5): a relayer pays `recipient` at least `outputAmount` of `outputToken` on the
/// destination chain, or the deposit is refunded to `depositor` here after `fillDeadline`. Both are
/// enforced by Across on-chain, so whoever submits a fill decides only when, never where (audit C-1).
interface ISpokePool {
    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}

/// @title SableAccount
/// @notice A user's trading account on Monad. The owner trades and withdraws freely. An optional
/// agent (in the app, a key in the user's browser) never sends transactions: it signs orders that
/// anyone may submit, so Sable's relayer pays the gas and is reimbursed out of the order itself.
/// Signed orders may only swap between tokens the Sable Shield registry lists, through allowed
/// routers, inside per-token caps, and may only withdraw to the owner or the owner's payout wallet.
/// Policy semantics follow SAW v1.5 (DECISIONS D9, D13, D16).
contract SableAccount is Initializable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    /// Caps are in the token's own units: no oracle, so a cap can't be bypassed by valuing one
    /// token in another (SAW M-1).
    struct Limit {
        uint128 perTrade;
        uint128 daily;
    }

    struct Spend {
        uint64 day; // UTC day index, block.timestamp / 1 days (SAW L-1)
        uint192 spent;
    }

    /// A trade the agent signed. `gasFee` is paid in `tokenOut`, out of the proceeds, and `minOut`
    /// is what the account keeps after it. The route calldata is signed by hash; epoch binds the authorization period.
    struct SwapOrder {
        address router;
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minOut;
        uint256 gasFee;
        uint256 nonce;
        uint256 deadline;
        uint64 epoch;
    }

    /// A withdrawal the agent signed. token == address(0) means native MON (paid from WMON);
    /// `gasFee` is paid in the same token, on top of `amount`. Epoch must match the current agent authorization.
    struct WithdrawOrder {
        address token;
        uint256 amount;
        address to;
        uint256 gasFee;
        uint256 nonce;
        uint256 deadline;
        uint64 epoch;
    }

    /// A limit order: spend `amountIn` of `tokenIn` when the price is right, earning in `vault` until
    /// then (DECISIONS D17). Local orders receive `tokenOut` on Monad and `minOut` is the limit price.
    /// Cross-chain orders (destChainId != 0, an Across chain id) deposit into Across, which delivers at
    /// least `destMinOut` of `destToken` to `recipient` on the destination chain or refunds this account.
    /// The public half of an order: only what custody needs. The limit lives in `commit`, so the
    /// chain never shows the price, what it buys or where it goes until the order fills (D20).
    struct OrderParams {
        address tokenIn;
        address vault;
        uint64 deadline;
        uint128 amountIn;
        bytes32 commit; // keccak256(abi.encode(Secret))
    }

    /// The hidden half, revealed by the keeper in the same transaction that fills it.
    /// `salt` is random, so the price can't be guessed by hashing candidate limits.
    struct Secret {
        address tokenOut;
        uint64 destChainId; // Across chain ids (Solana's exceeds uint32)
        uint128 minOut;
        uint128 destMinOut;
        bytes32 recipient;
        bytes32 destToken;
        bytes32 salt;
    }

    struct LimitOrder {
        OrderParams p;
        uint256 shares; // vault shares holding this order's funds
        bool byAgent; // the Shield listing and the approved recipient are checked when it fills
    }

    bytes32 private constant PLACE_TYPEHASH = keccak256(
        "PlaceOrder(address tokenIn,address vault,uint64 deadline,uint128 amountIn,bytes32 commit,uint256 gasFee,uint256 nonce,uint256 sigDeadline,uint64 epoch)"
    );
    bytes32 private constant CANCEL_TYPEHASH =
        keccak256("CancelOrder(uint256 id,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch)");

    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "SwapOrder(address router,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch,bytes32 dataHash)"
    );
    bytes32 private constant WITHDRAW_TYPEHASH = keccak256(
        "WithdrawOrder(address token,uint256 amount,address to,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch)"
    );

    /// A signed order's gas fee is at most this share of what it moves, so a leaked agent key
    /// can't burn a balance through fees. Fees go to the protocol treasury, never to the submitter.
    uint256 public constant MAX_GAS_BPS = 500;

    TokenRegistry public immutable registry;
    IWMON public immutable wmon;

    address public owner;
    address public agent;
    /// Bumped on every agent change. The app derives the agent key from a wallet signature over
    /// the epoch. Signed orders bind it even when an owner reinstalls the same key.
    uint64 public agentEpoch;
    uint64 public cooldown;
    uint64 public lastAgentTrade;
    mapping(address => bool) public routerAllowed;
    /// Owner overrides of the registry caps for this account; zero means "use the registry".
    mapping(address => Limit) public limitOf;
    mapping(address => Spend) public spendOf;
    /// A second wallet the owner approved for instant withdrawals (an exchange, a cold wallet).
    address public payout;
    mapping(uint256 => bool) public nonceUsed;
    mapping(uint256 => LimitOrder) internal _orders;
    uint256 public orderCount;
    /// Per destination chain, where the agent may send cross-chain orders (e.g. the owner's Solana
    /// wallet). Only the owner sets it, so a leaked agent key can't point a fill at its own address.
    mapping(uint64 => bytes32) public crossRecipient;

    event Swapped(
        address indexed by, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeePaid(address indexed token, address indexed to, uint256 amount);
    event GasPaid(address indexed token, address indexed to, uint256 amount);
    event AgentSet(address agent, uint64 epoch);
    event LimitSet(address indexed token, uint128 perTrade, uint128 daily);
    event RouterSet(address indexed router, bool allowed);
    event CooldownSet(uint64 cooldown);
    event PayoutSet(address payout);
    event OrderPlaced(uint256 indexed id, address indexed tokenIn, address indexed vault, uint128 amountIn, bytes32 commit);
    event OrderFilled(uint256 indexed id, uint256 spent, uint256 amountOut, uint256 yieldKept);
    event CrossFilled(
        uint256 indexed id, uint64 indexed destChainId, bytes32 recipient, bytes32 destToken, uint256 paid, uint256 outputAmount
    );
    event OrderCancelled(uint256 indexed id, uint256 returned);
    event CrossRecipientSet(uint64 indexed chainId, bytes32 recipient);

    error NotOwner();
    error NotAuthorized();
    error RouterNotAllowed();
    error TokenNotAllowed();
    error ExceedsPerTrade();
    error ExceedsDaily();
    error CooldownActive();
    error ZeroMinOut();
    error InsufficientOutput(uint256 received, uint256 minOut);
    error OverSpent();
    error NativeTransferFailed();
    error Expired();
    error NonceUsed();
    error GasFeeTooHigh();
    error NoOrder();
    error BadOrder();
    error VaultNotAllowed();
    error NoSpokePool();
    error Paused();
    error OrderTooSmall();
    error CrossTooLarge();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// EIP712's domain uses the clone's own address (OZ rebuilds it when address(this) differs
    /// from the implementation), so an order signed for one account can't run on another.
    constructor(TokenRegistry registry_, IWMON wmon_) EIP712("SableAccount", "5") {
        registry = registry_;
        wmon = wmon_;
        _disableInitializers();
    }

    /// @dev Called once by the factory in the same transaction that deploys the clone.
    function initialize(address owner_, address agent_, address[] calldata routers, uint64 cooldown_)
        external
        initializer
    {
        owner = owner_;
        agent = agent_;
        cooldown = cooldown_;
        for (uint256 i; i < routers.length; i++) {
            routerAllowed[routers[i]] = true;
            emit RouterSet(routers[i], true);
        }
        emit AgentSet(agent_, 0);
        // MON sent to the predicted address before the account existed arrived without receive();
        // wrap it now so the deposit address works for native MON from the first second.
        if (address(this).balance != 0) wmon.deposit{value: address(this).balance}();
    }

    /// @notice Native MON sent to the account is wrapped on arrival, so a deposit is a plain send.
    receive() external payable {
        if (msg.sender != address(wmon)) wmon.deposit{value: msg.value}();
    }

    // ───────────────────────── trading ─────────────────────────

    /// @notice The owner swaps `amountIn` of `tokenIn` through an allowed router using calldata built
    /// off-chain (e.g. by an aggregator API). The protocol fee is taken from `amountIn` first, so the
    /// route must be built for `amountIn - fee`. `tokenOut` must arrive here, at least `minOut`, and
    /// the router can never pull more than it was approved.
    function swap(
        address router,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        bytes calldata data
    ) external onlyOwner nonReentrant returns (uint256) {
        return _swap(SwapOrder(router, tokenIn, amountIn, tokenOut, minOut, 0, 0, 0, 0), data);
    }

    /// @notice Runs a swap the agent signed. Anyone may submit it; the Shield listing and caps apply,
    /// and `gasFee` (in `tokenOut`) goes to the treasury that funds the relayer.
    function swapWithSig(SwapOrder calldata o, bytes calldata data, bytes calldata sig)
        external
        nonReentrant
        returns (uint256)
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
        _useAgentSig(structHash, o.nonce, o.deadline, o.epoch, sig);
        _checkAgent(o.tokenIn, o.amountIn, o.tokenOut);
        return _swap(o, data);
    }

    function _swap(SwapOrder memory o, bytes calldata data) private returns (uint256 amountOut) {
        if (!routerAllowed[o.router]) revert RouterNotAllowed();
        if (o.minOut == 0) revert ZeroMinOut(); // an unbounded swap lets the router keep the input
        IERC20 tokenIn = IERC20(o.tokenIn);
        IERC20 tokenOut = IERC20(o.tokenOut);

        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));
        tokenIn.forceApprove(o.router, _takeFee(o.tokenIn, o.amountIn));
        (bool ok, bytes memory ret) = o.router.call(data);
        if (!ok) _bubble(ret);
        tokenIn.forceApprove(o.router, 0); // no leftover allowance (PayClaw H-1)

        if (inBefore - tokenIn.balanceOf(address(this)) > o.amountIn) revert OverSpent();
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < o.minOut + o.gasFee) revert InsufficientOutput(amountOut, o.minOut + o.gasFee);
        if (o.gasFee != 0) {
            _payGas(o.tokenOut, o.gasFee, amountOut);
            amountOut -= o.gasFee;
        }
        emit Swapped(msg.sender == owner ? owner : agent, o.tokenIn, o.tokenOut, o.amountIn, amountOut);
    }

    /// @notice Current Shield caps, optionally tightened per component by the owner's local limits.
    /// Delisted tokens have zero caps; a local daily limit of zero inherits the whole listing.
    function capOf(address token) public view returns (Limit memory lim) {
        (lim.perTrade, lim.daily) = registry.listingOf(token);
        Limit memory local = limitOf[token];
        if (local.daily != 0) {
            if (local.perTrade < lim.perTrade) lim.perTrade = local.perTrade;
            if (local.daily < lim.daily) lim.daily = local.daily;
        }
    }

    /// Both sides must be allowed (the agent only ever holds Shield-listed tokens); caps apply to
    /// what it spends. Hard caps always revert: an over-limit trade is left for the owner to sign
    /// directly (SAW v1.5, hard caps before escalation).
    function _checkAgent(address tokenIn, uint256 amountIn, address tokenOut) internal {
        Limit memory lim = capOf(tokenIn);
        if (lim.daily == 0 || capOf(tokenOut).daily == 0) revert TokenNotAllowed();
        if (amountIn > lim.perTrade) revert ExceedsPerTrade();
        uint256 last = lastAgentTrade; // 0 = the agent has never traded
        if (cooldown != 0 && last != 0 && block.timestamp < last + cooldown) revert CooldownActive();

        uint64 today = uint64(block.timestamp / 1 days);
        Spend memory s = spendOf[tokenIn];
        uint256 spent = (s.day == today ? s.spent : 0) + amountIn;
        if (spent > lim.daily) revert ExceedsDaily();
        spendOf[tokenIn] = Spend(today, uint192(spent));
        lastAgentTrade = uint64(block.timestamp);
    }

    /// Pays the protocol fee out of `amountIn` and returns what is left for the route.
    function _takeFee(address token, uint256 amountIn) private returns (uint256 net) {
        (uint16 feeBps, address feeTo) = registry.fee();
        uint256 fee = amountIn * feeBps / 10_000;
        if (fee != 0) {
            IERC20(token).safeTransfer(feeTo, fee);
            emit FeePaid(token, feeTo, fee);
        }
        return amountIn - fee;
    }

    /// Reimburses the relayer's gas to the treasury, capped at MAX_GAS_BPS of `moved`.
    function _payGas(address token, uint256 gasFee, uint256 moved) private {
        if (gasFee * 10_000 > moved * MAX_GAS_BPS) revert GasFeeTooHigh();
        (, address feeTo) = registry.fee();
        IERC20(token).safeTransfer(feeTo, gasFee);
        emit GasPaid(token, feeTo, gasFee);
    }

    /// One use per signature: unexpired, globally fresh nonce, current agent and epoch.
    function _useAgentSig(bytes32 structHash, uint256 nonce, uint256 deadline, uint64 epoch, bytes calldata sig)
        private
    {
        if (block.timestamp > deadline) revert Expired();
        if (nonceUsed[nonce]) revert NonceUsed();
        address a = agent;
        if (epoch != agentEpoch || a == address(0) || ECDSA.recover(_hashTypedDataV4(structHash), sig) != a) {
            revert NotAuthorized();
        }
        nonceUsed[nonce] = true;
    }

    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    // ───────────────────────── limit orders (D17) ─────────────────────────

    /// @notice Place a limit order from the account's balance. Its funds move into `p.vault`, an
    /// allowlisted ERC-4626 vault of `tokenIn`, and earn there until the order fills or is cancelled.
    function placeOrder(OrderParams calldata p) external onlyOwner nonReentrant returns (uint256) {
        return _place(p, false);
    }

    /// @notice An order the agent signed, relayed by anyone. Agent caps apply to `amountIn` now; the
    /// Shield listing of what it buys, or the owner-approved recipient, is checked when it fills.
    /// `gasFee` (in `tokenIn`, from the account's balance, capped like swaps) repays the relayer, so
    /// relaying can't be abused for free (audit H-2).
    function placeOrderWithSig(
        OrderParams calldata p,
        uint256 gasFee,
        uint256 nonce,
        uint256 sigDeadline,
        uint64 epoch,
        bytes calldata sig
    ) external nonReentrant returns (uint256) {
        // All OrderParams fields are static, so abi.encode lays them out exactly as EIP-712 encodeData.
        _useAgentSig(keccak256(abi.encode(PLACE_TYPEHASH, p, gasFee, nonce, sigDeadline, epoch)), nonce, sigDeadline, epoch, sig);
        _checkAgent(p.tokenIn, p.amountIn, p.tokenIn);
        if (gasFee != 0) _payGas(p.tokenIn, gasFee, p.amountIn);
        return _place(p, true);
    }

    function _place(OrderParams calldata p, bool byAgent) private returns (uint256 id) {
        if (registry.newOrdersPaused()) revert Paused();
        if (p.commit == bytes32(0) || p.amountIn == 0 || p.deadline <= block.timestamp) revert BadOrder();
        (uint128 minAmount,) = registry.orderBounds(p.tokenIn);
        if (p.amountIn < minAmount) revert OrderTooSmall();
        // The owner may pick any ERC-4626 vault of the order's token (the app scores and labels it);
        // its risk is bounded to this order, approved for exactly `amountIn`. The agent only uses
        // vaults the registry allows, so a leaked fast key can't park funds in a hostile vault.
        if ((byAgent && !registry.vaultAllowed(p.vault)) || IERC4626(p.vault).asset() != p.tokenIn) revert VaultNotAllowed();

        IERC20(p.tokenIn).forceApprove(p.vault, p.amountIn);
        uint256 shares = IERC4626(p.vault).deposit(p.amountIn, address(this));
        IERC20(p.tokenIn).forceApprove(p.vault, 0);
        id = ++orderCount;
        _orders[id] = LimitOrder(p, shares, byAgent);
        emit OrderPlaced(id, p.tokenIn, p.vault, p.amountIn, p.commit);
    }

    /// @notice A keeper fills a local order when the market meets its limit, revealing its secret.
    /// The order's shares are redeemed, `amountIn` (or what they are worth, if less) is swapped, and
    /// any yield above `amountIn` stays in the account. `minOut` binds: no worse than the limit.
    function fillOrder(uint256 id, Secret calldata s, address router, bytes calldata data, uint256 gasFee)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        (OrderParams memory p, uint256 spend, uint256 kept) = _takeOrder(id, s, false);
        amountOut = _swap(SwapOrder(router, p.tokenIn, spend, s.tokenOut, s.minOut, gasFee, 0, 0, 0), data);
        emit OrderFilled(id, spend, amountOut, kept);
    }

    /// How long Across relayers have to deliver before the deposit is refunded to this account.
    uint32 public constant CROSS_FILL_WINDOW = 1 hours;

    /// @notice A keeper fills a cross-chain order through Across. The contract builds the whole deposit
    /// from the revealed order: recipient, output token and destination are the owner's, and the
    /// output can't be below `destMinOut`. The keeper picks only `outputAmount` (at least the limit;
    /// more is better for the owner) and a recent `quoteTimestamp`.
    function fillCrossOrder(uint256 id, Secret calldata s, uint256 outputAmount, uint32 quoteTimestamp, uint256 gasFee)
        external
        nonReentrant
    {
        (OrderParams memory p, uint256 spend, uint256 kept) = _takeOrder(id, s, true);
        if (outputAmount < s.destMinOut) revert BadOrder();
        if (registry.crossFillsPaused()) revert Paused();
        (, uint128 maxCross) = registry.orderBounds(p.tokenIn);
        if (maxCross != 0 && p.amountIn > maxCross) revert CrossTooLarge();
        address pool = registry.acrossSpokePool();
        if (pool == address(0)) revert NoSpokePool();
        uint256 net = _takeFee(p.tokenIn, spend);
        if (gasFee != 0) {
            _payGas(p.tokenIn, gasFee, net);
            net -= gasFee;
        }
        _depositAcross(pool, s, p.tokenIn, net, outputAmount, quoteTimestamp);
        emit CrossFilled(id, s.destChainId, s.recipient, s.destToken, net, outputAmount);
        emit OrderFilled(id, spend, net, kept);
    }

    /// The Across deposit: every field but the quote time and the (≥ limit) output comes from the order.
    function _depositAcross(
        address pool,
        Secret calldata s,
        address tokenIn,
        uint256 net,
        uint256 outputAmount,
        uint32 quoteTimestamp
    ) private {
        IERC20(tokenIn).forceApprove(pool, net); // exactly: the pool can't take more
        // Twelve arguments overflow the stack in one call, so the calldata is encoded in two halves:
        // eleven static words, then the empty \`message\` (its offset, 12 words in, and a zero length).
        bytes memory head = abi.encode(
            bytes32(uint256(uint160(address(this)))), // depositor: refunds come back here
            s.recipient,
            bytes32(uint256(uint160(tokenIn))),
            s.destToken,
            net,
            outputAmount
        );
        bytes memory tail = abi.encode(
            uint256(s.destChainId),
            bytes32(0), // no exclusive relayer: any relayer may deliver
            quoteTimestamp,
            uint32(block.timestamp) + CROSS_FILL_WINDOW,
            uint32(0),
            uint256(12 * 32), // message offset
            uint256(0) // message length
        );
        (bool ok, bytes memory ret) = pool.call(bytes.concat(ISpokePool.deposit.selector, head, tail));
        if (!ok) _bubble(ret);
        IERC20(tokenIn).forceApprove(pool, 0);
    }

    /// Keeper-only: checks the revealed secret, the order's kind and expiry, deletes it and redeems
    /// its shares. A secret that doesn't match, or is malformed, leaves the order to be cancelled.
    function _takeOrder(uint256 id, Secret calldata s, bool cross)
        private
        returns (OrderParams memory p, uint256 spend, uint256 kept)
    {
        if (!registry.isKeeper(msg.sender)) revert NotAuthorized();
        LimitOrder memory o = _orders[id];
        p = o.p;
        if (p.amountIn == 0) revert NoOrder();
        if (keccak256(abi.encode(s)) != p.commit || (s.destChainId != 0) != cross) revert BadOrder();
        bool shapeOk = cross
            ? s.tokenOut == address(0) && s.recipient != bytes32(0) && s.destMinOut != 0
            : s.tokenOut != address(0) && s.minOut != 0;
        if (!shapeOk) revert BadOrder();
        if (o.byAgent && cross && s.recipient != crossRecipient[s.destChainId]) revert NotAuthorized();
        if (o.byAgent && !cross && capOf(s.tokenOut).daily == 0) revert TokenNotAllowed();
        if (block.timestamp > p.deadline) revert Expired();
        delete _orders[id];
        uint256 assets = _redeem(o);
        spend = assets < p.amountIn ? assets : p.amountIn;
        kept = assets - spend;
    }

    /// @notice Cancel an order: its shares are redeemed into the account, yield included. The owner
    /// may cancel any time; a keeper only after the order expired (it can only return funds).
    function cancelOrder(uint256 id) external nonReentrant {
        bool expiredByKeeper = registry.isKeeper(msg.sender) && block.timestamp > _orders[id].p.deadline;
        if (msg.sender != owner && !expiredByKeeper) revert NotAuthorized();
        _cancel(id);
    }

    /// @notice A cancel the agent signed; `gasFee` (in `tokenIn`, out of what comes back) repays the relayer.
    function cancelOrderWithSig(uint256 id, uint256 gasFee, uint256 nonce, uint256 deadline, uint64 epoch, bytes calldata sig)
        external
        nonReentrant
    {
        _useAgentSig(keccak256(abi.encode(CANCEL_TYPEHASH, id, gasFee, nonce, deadline, epoch)), nonce, deadline, epoch, sig);
        (address tokenIn, uint256 returned) = _cancel(id);
        if (gasFee != 0) _payGas(tokenIn, gasFee, returned);
    }

    function _cancel(uint256 id) private returns (address tokenIn, uint256 returned) {
        LimitOrder memory o = _orders[id];
        if (o.p.amountIn == 0) revert NoOrder();
        delete _orders[id];
        returned = _redeem(o);
        tokenIn = o.p.tokenIn;
        emit OrderCancelled(id, returned);
    }

    /// What the order's shares really paid back. The owner may pick any vault, and one could report more
    /// than it sends; trusting its word would let a fill spend the account's other funds.
    function _redeem(LimitOrder memory o) private returns (uint256) {
        IERC20 token = IERC20(o.p.tokenIn);
        uint256 before = token.balanceOf(address(this));
        IERC4626(o.p.vault).redeem(o.shares, address(this), address(this));
        return token.balanceOf(address(this)) - before;
    }

    function order(uint256 id) external view returns (LimitOrder memory) {
        return _orders[id];
    }

    /// @notice What an open order is worth right now, yield included; 0 once filled or cancelled.
    function orderValue(uint256 id) external view returns (uint256) {
        LimitOrder memory o = _orders[id];
        return o.p.amountIn == 0 ? 0 : IERC4626(o.p.vault).convertToAssets(o.shares);
    }

    // ───────────────────────── withdrawals ─────────────────────────

    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Withdraw WMON as native MON.
    function withdrawNative(uint256 amount, address payable to) external onlyOwner nonReentrant {
        _sendNative(amount, to);
    }

    /// @notice A withdrawal the agent signed: only to the owner or the approved payout wallet, so a
    /// leaked agent key can move funds only to places the owner chose.
    function withdrawWithSig(WithdrawOrder calldata o, bytes calldata sig) external nonReentrant {
        _useAgentSig(
            keccak256(abi.encode(WITHDRAW_TYPEHASH, o.token, o.amount, o.to, o.gasFee, o.nonce, o.deadline, o.epoch)),
            o.nonce,
            o.deadline,
            o.epoch,
            sig
        );
        if (o.to != owner && (o.to != payout || payout == address(0))) revert NotAuthorized();
        bool native = o.token == address(0);
        if (o.gasFee != 0) _payGas(native ? address(wmon) : o.token, o.gasFee, o.amount);
        if (native) {
            _sendNative(o.amount, payable(o.to));
        } else {
            IERC20(o.token).safeTransfer(o.to, o.amount);
            emit Withdrawn(o.token, o.to, o.amount);
        }
    }

    function _sendNative(uint256 amount, address payable to) private {
        wmon.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(address(0), to, amount);
    }

    // ───────────────────────── owner settings ─────────────────────────

    /// @notice Approve one extra wallet for instant withdrawals. address(0) removes it.
    function setPayout(address payout_) external onlyOwner {
        payout = payout_;
        emit PayoutSet(payout_);
    }

    /// @notice Where agent-placed cross-chain orders to `chainId` may deliver. bytes32(0) disables it.
    function setCrossRecipient(uint64 chainId, bytes32 recipient) external onlyOwner {
        crossRecipient[chainId] = recipient;
        emit CrossRecipientSet(chainId, recipient);
    }

    /// @notice Replace or remove (address(0)) the agent. Every change starts a new key epoch.
    function setAgent(address agent_) external onlyOwner {
        agent = agent_;
        emit AgentSet(agent_, ++agentEpoch);
    }

    /// @notice Tighten current Shield caps for this account. A zero daily limit clears the override.
    function setLimit(address token, uint128 perTrade, uint128 daily) external onlyOwner {
        limitOf[token] = Limit(perTrade, daily);
        emit LimitSet(token, perTrade, daily);
    }

    function setRouter(address router, bool allowed) external onlyOwner {
        routerAllowed[router] = allowed;
        emit RouterSet(router, allowed);
    }

    function setCooldown(uint64 cooldown_) external onlyOwner {
        cooldown = cooldown_;
        emit CooldownSet(cooldown_);
    }

    /// @notice What the agent can still spend of `token` today.
    function agentAllowance(address token) external view returns (uint256) {
        Limit memory lim = capOf(token);
        Spend memory s = spendOf[token];
        uint256 spent = s.day == block.timestamp / 1 days ? s.spent : 0;
        return spent >= lim.daily ? 0 : lim.daily - spent;
    }

    /// @notice The EIP-712 domain separator orders are signed against.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
