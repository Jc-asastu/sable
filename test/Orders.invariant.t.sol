// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentOrders} from "./helpers/AgentOrders.sol";
import {SableAccount, IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {MockToken, MockWMON, MockVault} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockSpokePool} from "./LimitOrders.t.sol";

/// Drives a v5 account with random owner and agent actions and an **adversarial keeper**: it picks
/// the router's behaviour, outputs, gas fees, Across outputs, and sometimes reveals a tampered secret.
/// Ghost variables record what each successful call did, so the invariants can judge it.
contract OrdersHandler is AgentOrders {
    MockToken public usdc;
    MockToken public meme;
    MockVault public vault;
    MockRouter public router;
    MockSpokePool public pool;
    SableAccount public account;
    TokenRegistry public registry;
    address public owner;
    uint256 internal agentKey;
    address public keeper;

    bytes32 public constant SOL_WALLET = keccak256("owner's solana wallet");
    uint64 public constant SOLANA = 34268394551451;
    bytes32 private constant PLACE_TYPEHASH = keccak256(
        "PlaceOrder(address tokenIn,address vault,uint64 deadline,uint128 amountIn,bytes32 commit,uint256 gasFee,uint256 nonce,uint256 sigDeadline,uint64 epoch)"
    );

    struct Open {
        uint256 id;
        SableAccount.Secret s;
    }

    Open[] internal open;
    uint256 internal nonce;
    uint256 public openShares; // ghost: shares the open orders hold
    uint256 public limitBreaches; // ghost: a local fill that delivered less than its limit
    uint256 public crossBreaches; // ghost: a cross fill to another recipient or below the limit
    uint256 public replays; // ghost: an already-used agent signature that worked again
    uint256 public fills;

    bytes internal lastSig;
    SableAccount.OrderParams internal lastP;
    uint256 internal lastNonce;
    uint256 internal lastGas;
    uint256 internal lastDl;

    constructor(
        MockToken usdc_,
        MockToken meme_,
        MockVault vault_,
        MockRouter router_,
        MockSpokePool pool_,
        SableAccount account_,
        TokenRegistry registry_,
        address owner_,
        uint256 agentKey_,
        address keeper_
    ) {
        (usdc, meme, vault, router, pool, account, registry) = (usdc_, meme_, vault_, router_, pool_, account_, registry_);
        (owner, agentKey, keeper) = (owner_, agentKey_, keeper_);
    }

    function _secret(bool cross, uint256 seed) internal view returns (SableAccount.Secret memory s) {
        s.salt = keccak256(abi.encode(seed, nonce));
        if (cross) (s.destChainId, s.destMinOut, s.recipient) = (SOLANA, uint128(bound(seed, 1, 1e12)), SOL_WALLET);
        else (s.tokenOut, s.minOut) = (address(meme), uint128(bound(seed, 1, 1e24)));
    }

    function _params(uint128 amountIn, SableAccount.Secret memory s) internal view returns (SableAccount.OrderParams memory p) {
        (p.tokenIn, p.vault, p.deadline, p.amountIn, p.commit) =
            (address(usdc), address(vault), uint64(block.timestamp + 7 days), amountIn, keccak256(abi.encode(s)));
    }

    function _track(uint256 id, SableAccount.Secret memory s) internal {
        open.push(Open(id, s));
        openShares += account.order(id).shares;
    }

    // ── owner and agent ──

    function placeByOwner(uint128 amount, bool cross, uint256 seed) external {
        amount = uint128(bound(amount, 1, usdc.balanceOf(address(account)) + 1));
        SableAccount.Secret memory s = _secret(cross, seed);
        vm.prank(owner);
        try account.placeOrder(_params(amount, s)) returns (uint256 id) { _track(id, s); } catch {}
    }

    function placeByAgent(uint128 amount, bool cross, uint256 seed, uint256 gasFee) external {
        amount = uint128(bound(amount, 1, 400e6));
        gasFee = bound(gasFee, 0, amount / 10); // sometimes above the 5% cap
        SableAccount.Secret memory s = _secret(cross, seed);
        SableAccount.OrderParams memory p = _params(amount, s);
        (uint256 n, uint256 dl) = (++nonce, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(address(account), agentKey, keccak256(abi.encode(
            PLACE_TYPEHASH, p.tokenIn, p.vault, p.deadline, p.amountIn, p.commit, gasFee, n, dl, account.agentEpoch()
        )));
        try account.placeOrderWithSig(p, gasFee, n, dl, account.agentEpoch(), sig) returns (uint256 id) {
            _track(id, s);
            (lastSig, lastP, lastNonce, lastGas, lastDl) = (sig, p, n, gasFee, dl);
        } catch {}
    }

    /// Anyone replays the last agent placement: it must never work twice.
    function replayLastAgentOrder() external {
        if (lastSig.length == 0) return;
        try account.placeOrderWithSig(lastP, lastGas, lastNonce, lastDl, account.agentEpoch(), lastSig) returns (uint256) {
            replays++;
        } catch {}
    }

    function cancelByOwner(uint256 i) external {
        if (open.length == 0) return;
        i = bound(i, 0, open.length - 1);
        uint256 shares = account.order(open[i].id).shares;
        vm.prank(owner);
        try account.cancelOrder(open[i].id) { _close(i, shares); } catch {}
    }

    function accrue(uint256 amount) external {
        vault.accrue(bound(amount, 0, 5e6));
    }

    // ── the adversarial keeper ──

    function keeperFillLocal(uint256 i, uint8 mode, uint256 out, uint256 gasFee, bool tamper) external {
        if (open.length == 0) return;
        i = bound(i, 0, open.length - 1);
        SableAccount.Secret memory s = open[i].s;
        if (s.destChainId != 0) return;
        if (tamper) s.minOut = s.minOut / 2; // reveal a worse limit than the owner committed to
        router.setMode(MockRouter.Mode(bound(mode, 0, 3)));
        uint256 spend = account.orderValue(open[i].id);
        spend = spend < account.order(open[i].id).p.amountIn ? spend : account.order(open[i].id).p.amountIn;
        uint256 net = spend - spend * 30 / 10_000;
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), net, address(meme), bound(out, 0, 2e24)));
        uint256 shares = account.order(open[i].id).shares;
        uint256 before = meme.balanceOf(address(account));
        vm.prank(keeper);
        try account.fillOrder(open[i].id, s, address(router), data, bound(gasFee, 0, 1e24)) {
            if (meme.balanceOf(address(account)) - before < open[i].s.minOut) limitBreaches++;
            fills++;
            _close(i, shares);
        } catch {}
        router.setMode(MockRouter.Mode.Honest);
    }

    function keeperFillCross(uint256 i, uint256 outputAmount, uint256 gasFee, bool tamper) external {
        if (open.length == 0) return;
        i = bound(i, 0, open.length - 1);
        SableAccount.Secret memory s = open[i].s;
        if (s.destChainId == 0) return;
        if (tamper) s.recipient = keccak256("attacker"); // point the fill at someone else
        uint256 shares = account.order(open[i].id).shares;
        vm.prank(keeper);
        try account.fillCrossOrder(open[i].id, s, bound(outputAmount, 0, 2e12), uint32(block.timestamp), bound(gasFee, 0, 1e9)) {
            if (pool.recipient() != SOL_WALLET || pool.outputAmount() < open[i].s.destMinOut) crossBreaches++;
            fills++;
            _close(i, shares);
        } catch {}
    }

    function _close(uint256 i, uint256 shares) internal {
        openShares -= shares;
        open[i] = open[open.length - 1];
        open.pop();
    }
}

contract OrdersInvariantTest is Test {
    OrdersHandler handler;
    MockToken usdc;
    MockVault vault;
    MockRouter router;
    MockSpokePool pool;
    SableAccount account;
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    uint256 agentKey = 0xA11CE;

    function setUp() public {
        usdc = new MockToken("USDC", 6);
        MockToken meme = new MockToken("MEME", 18);
        MockWMON wmon = new MockWMON();
        router = new MockRouter();
        pool = new MockSpokePool();
        SableAccountFactory factory = new SableAccountFactory(address(this), IWMON(address(wmon)));
        TokenRegistry registry = factory.registry();
        vault = new MockVault(usdc);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(meme));
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 500e6, daily: 100_000e6});
        caps[1] = TokenRegistry.Listing({perTrade: 1e30, daily: 1e30});
        registry.list(tokens, caps);
        registry.setFee(30, treasury);
        registry.setVault(address(vault), true);
        registry.setKeeper(keeper, true);
        registry.setAcrossSpokePool(address(pool));
        factory.openToEveryone();

        address owner = makeAddr("owner");
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(vm.addr(agentKey), routers, 0, 0)));
        usdc.mint(address(account), 10_000e6);
        vm.prank(owner);
        account.setCrossRecipient(34268394551451, keccak256("owner's solana wallet"));

        handler = new OrdersHandler(usdc, meme, vault, router, pool, account, registry, owner, agentKey, keeper);
        targetContract(address(handler));
        // Only the handler's actions: not the helpers it inherits from forge-std.
        bytes4[] memory actions = new bytes4[](8);
        actions[0] = OrdersHandler.placeByOwner.selector;
        actions[1] = OrdersHandler.placeByAgent.selector;
        actions[2] = OrdersHandler.replayLastAgentOrder.selector;
        actions[3] = OrdersHandler.cancelByOwner.selector;
        actions[4] = OrdersHandler.accrue.selector;
        actions[5] = OrdersHandler.keeperFillLocal.selector;
        actions[6] = OrdersHandler.keeperFillCross.selector;
        actions[7] = OrdersHandler.placeByOwner.selector; // placing twice as often keeps orders open to fill
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// Account USDC is only ever in the account, its vault, the treasury, a swap it paid, or Across.
    /// Never with the keeper, the agent, the router's thief, or anyone else.
    function invariant_usdcOnlyInAllowedPlaces() public view {
        uint256 allowed = usdc.balanceOf(address(account)) + usdc.balanceOf(address(vault)) + usdc.balanceOf(treasury)
            + usdc.balanceOf(address(router)) + usdc.balanceOf(address(pool));
        assertEq(allowed, usdc.totalSupply(), "USDC leaked to an address that should never hold it");
        assertEq(usdc.balanceOf(router.THIEF()), 0);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    /// The account's vault shares are exactly the open orders' shares.
    function invariant_vaultSharesBackOpenOrders() public view {
        assertEq(vault.balanceOf(address(account)), handler.openShares());
    }

    function invariant_fillsNeverBreakTheLimit() public view {
        assertEq(handler.limitBreaches(), 0, "a local fill delivered less than the committed limit");
        assertEq(handler.crossBreaches(), 0, "a cross fill paid another recipient or less than the limit");
    }

    /// Not vacuous: the handler's paths really fill orders, locally and through Across (an invariant
    /// that never sees a fill proves nothing). A probe invariant asserting zero fills fails within a few calls.
    function test_theHandlerReallyFills() public {
        handler.placeByOwner(100e6, false, 5);
        handler.placeByOwner(100e6, true, 5);
        handler.keeperFillLocal(0, 0, 1e24, 0, false);
        handler.keeperFillCross(1, 2e12, 0, false);
        assertEq(handler.fills(), 2);
        assertEq(handler.openShares(), 0);
    }

    function invariant_agentSignaturesWorkOnce() public view {
        assertEq(handler.replays(), 0);
    }
}
