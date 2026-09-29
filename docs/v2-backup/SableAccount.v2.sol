// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenRegistry} from "./TokenRegistry.sol";

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title SableAccount
/// @notice A user's trading account on Monad. The owner trades and withdraws freely. An optional
/// agent (in the app, a session key in the user's browser) may only swap between tokens the
/// Sable Shield registry lists, through allowed routers, inside per-token caps enforced here.
/// The agent can only send funds to the owner, so a leaked agent key is bounded by the caps.
/// Policy semantics follow SAW v1.5 (DECISIONS D9, D13).
contract SableAccount is Initializable, ReentrancyGuard {
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

    TokenRegistry public immutable registry;
    IWMON public immutable wmon;

    address public owner;
    address public agent;
    uint64 public cooldown;
    uint64 public lastAgentTrade;
    mapping(address => bool) public routerAllowed;
    /// Owner overrides of the registry caps for this account; zero means "use the registry".
    mapping(address => Limit) public limitOf;
    mapping(address => Spend) public spendOf;
    /// A second wallet the owner approved for instant withdrawals (an exchange, a cold wallet).
    address public payout;
    /// MON the agent has taken from the account for its own gas, per UTC day.
    Spend public agentGas;

    /// The agent may refuel its gas from the account up to this much MON per UTC day.
    uint256 public constant AGENT_GAS_DAILY = 2 ether;

    event Swapped(
        address indexed by, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeePaid(address indexed token, address indexed to, uint256 amount);
    event AgentSet(address agent);
    event LimitSet(address indexed token, uint128 perTrade, uint128 daily);
    event RouterSet(address indexed router, bool allowed);
    event CooldownSet(uint64 cooldown);
    event PayoutSet(address payout);

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
    error ExceedsGasAllowance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(TokenRegistry registry_, IWMON wmon_) {
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
        emit AgentSet(agent_);
    }

    /// @notice Native MON sent to the account is wrapped on arrival, so a deposit is a plain send.
    receive() external payable {
        if (msg.sender != address(wmon)) wmon.deposit{value: msg.value}();
    }

    // ───────────────────────── trading ─────────────────────────

    /// @notice Swap `amountIn` of `tokenIn` through an allowed router using calldata built off-chain
    /// (e.g. by an aggregator API). The protocol fee is taken from `amountIn` first, so the route
    /// must be built for `amountIn - fee`. The result is checked here: `tokenOut` must arrive in
    /// this account, at least `minOut`, and the router can never pull more than it was approved.
    function swap(
        address router,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountOut) {
        bool isOwner = msg.sender == owner;
        if (!isOwner && (msg.sender != agent || agent == address(0))) revert NotAuthorized();
        if (!routerAllowed[router]) revert RouterNotAllowed();
        if (minOut == 0) revert ZeroMinOut(); // an unbounded swap lets the router keep the input
        if (!isOwner) _checkAgent(tokenIn, amountIn, tokenOut);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(router, _takeFee(tokenIn, amountIn));
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) _bubble(ret);
        IERC20(tokenIn).forceApprove(router, 0); // no leftover allowance (PayClaw H-1)

        if (inBefore - IERC20(tokenIn).balanceOf(address(this)) > amountIn) revert OverSpent();
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice The agent cap for `token`: the owner's override if set, else the Shield listing.
    function capOf(address token) public view returns (Limit memory lim) {
        lim = limitOf[token];
        if (lim.daily == 0) (lim.perTrade, lim.daily) = registry.listingOf(token);
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

    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    // ───────────────────────── owner ─────────────────────────

    /// The owner can send anywhere; the agent only to the owner or the payout wallet the owner
    /// approved. A leaked agent key can move funds only to places the owner chose.
    function _checkWithdraw(address to) internal view {
        if (msg.sender == owner) return;
        bool approved = to == owner || (to == payout && payout != address(0));
        if (msg.sender != agent || agent == address(0) || !approved) revert NotAuthorized();
    }

    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        _checkWithdraw(to);
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Withdraw WMON as native MON.
    function withdrawNative(uint256 amount, address payable to) external nonReentrant {
        _checkWithdraw(to);
        wmon.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(address(0), to, amount);
    }

    /// @notice The agent tops up its own gas from the account's WMON, capped per UTC day, so fast
    /// trading never has to ask the owner's wallet. A leaked key can take at most AGENT_GAS_DAILY a day.
    function refuelAgent(uint256 amount) external nonReentrant {
        if (msg.sender != agent || agent == address(0)) revert NotAuthorized();
        uint64 today = uint64(block.timestamp / 1 days);
        Spend memory g = agentGas;
        uint256 spent = (g.day == today ? g.spent : 0) + amount;
        if (spent > AGENT_GAS_DAILY) revert ExceedsGasAllowance();
        agentGas = Spend(today, uint192(spent));
        wmon.withdraw(amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @notice Approve one extra wallet for instant withdrawals. address(0) removes it.
    function setPayout(address payout_) external onlyOwner {
        payout = payout_;
        emit PayoutSet(payout_);
    }

    function setAgent(address agent_) external onlyOwner {
        agent = agent_;
        emit AgentSet(agent_);
    }

    /// @notice Override the Shield caps for this account (e.g. stricter ones). Zero clears it.
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
}
