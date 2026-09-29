// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SableAccount, IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {MockToken, MockWMON} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract SableAccountTest is Test {
    MockToken usdc;
    MockWMON wmon;
    MockRouter router;
    SableAccountFactory factory;
    TokenRegistry registry;
    SableAccount account;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockToken("USDC", 6);
        wmon = new MockWMON();
        router = new MockRouter();
        factory = new SableAccountFactory(address(this), IWMON(address(wmon)));
        registry = factory.registry();

        // Shield listings: the agent may trade these, within these caps
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(wmon));
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 50e6, daily: 200e6}); // USDC
        caps[1] = TokenRegistry.Listing({perTrade: 10_000e18, daily: 50_000e18}); // WMON
        registry.list(tokens, caps);

        address[] memory listed = new address[](1);
        listed[0] = owner;
        factory.setAllowed(listed, true);

        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(agent, routers, 0, 0)));
        usdc.mint(address(account), 1_000e6);
        wmon.mint(address(account), 100_000e18);
    }

    function _swap(address by, address tokenIn, uint256 amountIn, address tokenOut, uint256 out)
        internal
        returns (uint256)
    {
        bytes memory data = abi.encodeCall(MockRouter.swap, (tokenIn, amountIn, tokenOut, out));
        vm.prank(by);
        return account.swap(address(router), tokenIn, amountIn, tokenOut, out, data);
    }

    /// buy WMON with USDC at 0.03 USDC/WMON
    function _buy(address by, uint256 usdcIn) internal returns (uint256) {
        return _swap(by, address(usdc), usdcIn, address(wmon), usdcIn * 1e12 * 100 / 3);
    }

    // ── factory ──

    function test_factoryGivesPredictableAddress() public view {
        assertEq(factory.accountOf(owner), address(account));
        assertEq(account.owner(), owner);
        assertEq(account.agent(), agent);
        assertEq(address(account.registry()), address(registry), "clones share the Shield registry");
    }

    function test_oneAccountPerOwner() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.createAccount(agent, new address[](0), 0, 0);
    }

    function test_guardedLaunch() public {
        vm.prank(stranger);
        vm.expectRevert(SableAccountFactory.NotAllowed.selector);
        factory.createAccount(agent, new address[](0), 0, 0);

        vm.prank(stranger);
        vm.expectRevert();
        factory.openToEveryone(); // only the admin opens it

        factory.openToEveryone();
        vm.prank(stranger);
        factory.createAccount(agent, new address[](0), 0, 0);
        assertEq(SableAccount(payable(factory.accountOf(stranger))).owner(), stranger);
    }

    function test_implementationCannotBeInitialized() public {
        SableAccount impl = SableAccount(payable(factory.implementation()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger, stranger, new address[](0), 0);
    }

    // ── owner ──

    function test_ownerTradesWithoutLimits() public {
        assertGt(_buy(owner, 1_000e6), 0, "owner is not bound by agent caps");
    }

    function test_onlyOwnerWithdraws() public {
        vm.prank(agent);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdraw(address(usdc), 1e6, agent); // the agent can't send funds to itself
        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdraw(address(usdc), 1e6, stranger);

        vm.prank(owner);
        account.withdraw(address(usdc), 100e6, owner);
        assertEq(usdc.balanceOf(owner), 100e6);
    }

    // ── native MON ──

    function test_nativeDepositIsWrapped() public {
        vm.deal(owner, 5 ether);
        uint256 before = wmon.balanceOf(address(account));
        vm.prank(owner);
        (bool ok,) = address(account).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(wmon.balanceOf(address(account)) - before, 5 ether, "a plain send lands as WMON");
    }

    function test_withdrawNative() public {
        vm.deal(address(wmon), 1 ether); // backing for the mock's pre-minted WMON
        vm.prank(agent);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdrawNative(1 ether, payable(agent));

        vm.prank(owner);
        account.withdrawNative(1 ether, payable(owner));
        assertEq(owner.balance, 1 ether);
    }

    function test_agentWithdrawsOnlyToOwner() public {
        vm.prank(agent);
        account.withdraw(address(usdc), 100e6, owner);
        assertEq(usdc.balanceOf(owner), 100e6, "the fast key can return funds to the owner");

        vm.deal(address(wmon), 1 ether);
        vm.prank(agent);
        account.withdrawNative(1 ether, payable(owner));
        assertEq(owner.balance, 1 ether);
    }

    function test_agentWithdrawsToApprovedPayoutOnly() public {
        address exchange = makeAddr("exchange");
        vm.prank(agent);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdraw(address(usdc), 1e6, exchange); // not approved yet

        vm.prank(agent);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setPayout(agent); // the key can't approve a destination for itself

        vm.prank(owner);
        account.setPayout(exchange);
        vm.prank(agent);
        account.withdraw(address(usdc), 50e6, exchange);
        assertEq(usdc.balanceOf(exchange), 50e6, "instant withdrawal to the saved wallet");

        vm.prank(owner);
        account.setPayout(address(0));
        vm.prank(agent);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdraw(address(usdc), 1e6, exchange);
    }

    function test_refuelAgentCappedDaily() public {
        vm.deal(address(wmon), 10 ether); // backing for the mock's pre-minted WMON
        vm.warp(20 days + 1 hours);
        vm.prank(agent);
        account.refuelAgent(1.5 ether);
        assertEq(agent.balance, 1.5 ether);

        vm.prank(agent);
        vm.expectRevert(SableAccount.ExceedsGasAllowance.selector);
        account.refuelAgent(0.6 ether);

        vm.warp(21 days); // next UTC day
        vm.prank(agent);
        account.refuelAgent(2 ether);

        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.refuelAgent(1);
    }

    // ── protocol fee ──

    function test_feeTakenFromInputAndRouteGetsTheRest() public {
        address treasury = makeAddr("treasury");
        registry.setFee(30, treasury); // 0.30%
        uint256 amountIn = 10e6;
        uint256 fee = amountIn * 30 / 10_000;
        // the route is built for the net amount; the router can't pull a unit more
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), amountIn - fee, address(wmon), 1e18));
        vm.prank(agent);
        account.swap(address(router), address(usdc), amountIn, address(wmon), 1e18, data);
        assertEq(usdc.balanceOf(treasury), fee, "fee paid to the treasury");
        assertEq(usdc.balanceOf(address(account)), 1_000e6 - amountIn, "total spent = amountIn");
        assertEq(account.agentAllowance(address(usdc)), 200e6 - amountIn, "caps count the whole amount");
    }

    function test_feeIsCappedAtOnePercent() public {
        vm.expectRevert(TokenRegistry.FeeTooHigh.selector);
        registry.setFee(101, address(this));
        vm.expectRevert(TokenRegistry.FeeTooHigh.selector);
        registry.setFee(10, address(0));
        vm.prank(stranger);
        vm.expectRevert();
        registry.setFee(10, stranger);
    }

    // ── one-transaction onboarding ──

    function test_createFundsKeyAndDepositsInOneTx() public {
        address newcomer = makeAddr("newcomer");
        address key = makeAddr("key");
        factory.openToEveryone();
        vm.deal(newcomer, 5 ether);
        vm.prank(newcomer);
        address acct = factory.createAccount{value: 5 ether}(key, new address[](0), 0, 1 ether);
        assertEq(key.balance, 1 ether, "fast key funded");
        assertEq(wmon.balanceOf(acct), 4 ether, "the rest deposited as WMON");
    }

    function test_gasWithoutKeyIsRejected() public {
        factory.openToEveryone();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SableAccountFactory.GasExceedsValue.selector);
        factory.createAccount{value: 1 ether}(address(0), new address[](0), 0, 1 ether);
    }

    // ── Sable Shield ──

    function test_agentCannotTradeUnlistedToken() public {
        MockToken meme = new MockToken("MEME", 18);
        vm.expectRevert(SableAccount.TokenNotAllowed.selector);
        _swap(agent, address(usdc), 10e6, address(meme), 1e18);
    }

    function test_shieldListingEnablesToken() public {
        MockToken meme = new MockToken("MEME", 18);
        address[] memory t = new address[](1);
        t[0] = address(meme);
        TokenRegistry.Listing[] memory c = new TokenRegistry.Listing[](1);
        c[0] = TokenRegistry.Listing({perTrade: 1_000e18, daily: 5_000e18});
        registry.list(t, c);

        assertEq(_swap(agent, address(usdc), 10e6, address(meme), 400e18), 400e18, "buy a listed token");
        assertEq(_swap(agent, address(meme), 400e18, address(usdc), 9e6), 9e6, "and sell it back");
        vm.expectRevert(SableAccount.ExceedsPerTrade.selector);
        _swap(agent, address(meme), 1_000e18 + 1, address(usdc), 1);
    }

    function test_delistStopsAgentNotOwner() public {
        address[] memory t = new address[](1);
        t[0] = address(wmon);
        registry.delist(t);
        vm.expectRevert(SableAccount.TokenNotAllowed.selector);
        _buy(agent, 10e6);
        assertGt(_buy(owner, 10e6), 0, "the owner can always trade");
    }

    function test_ownerOverrideIsEnforced() public {
        vm.prank(owner);
        account.setLimit(address(usdc), 10e6, 20e6); // stricter than the Shield default
        vm.expectRevert(SableAccount.ExceedsPerTrade.selector);
        _buy(agent, 11e6);
        _buy(agent, 10e6);
        assertEq(account.agentAllowance(address(usdc)), 10e6);
    }

    function test_onlyCuratorLists() public {
        address[] memory t = new address[](1);
        t[0] = stranger;
        TokenRegistry.Listing[] memory c = new TokenRegistry.Listing[](1);
        c[0] = TokenRegistry.Listing({perTrade: 1, daily: 1});
        vm.prank(stranger);
        vm.expectRevert();
        registry.list(t, c);

        c[0] = TokenRegistry.Listing({perTrade: 0, daily: 1});
        vm.expectRevert(TokenRegistry.ZeroCap.selector);
        registry.list(t, c);
    }

    // ── agent limits ──

    function test_agentTradesWithinLimits() public {
        uint256 out = _buy(agent, 50e6);
        assertEq(out, uint256(50e6) * 1e12 * 100 / 3);
        assertEq(account.agentAllowance(address(usdc)), 150e6);
    }

    function test_agentPerTradeCap() public {
        vm.expectRevert(SableAccount.ExceedsPerTrade.selector);
        _buy(agent, 50e6 + 1);
    }

    function test_agentDailyCapResetsAtUtcMidnight() public {
        vm.warp(10 days + 1 hours);
        for (uint256 i; i < 4; i++) {
            _buy(agent, 50e6);
        }
        vm.expectRevert(SableAccount.ExceedsDaily.selector);
        _buy(agent, 1e6);

        vm.warp(11 days); // next UTC day
        _buy(agent, 50e6);
    }

    function test_cooldown() public {
        vm.prank(owner);
        account.setCooldown(60);
        _buy(agent, 10e6);
        vm.expectRevert(SableAccount.CooldownActive.selector);
        _buy(agent, 10e6);
        vm.warp(block.timestamp + 60);
        _buy(agent, 10e6);
    }

    function test_revokedAgentCannotTrade() public {
        vm.prank(owner);
        account.setAgent(address(0));
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        _buy(agent, 10e6);
    }

    function test_strangerCannotTradeOrConfigure() public {
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        _buy(stranger, 10e6);
        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setLimit(address(usdc), type(uint128).max, type(uint128).max);
    }

    // ── a bad route can't take funds ──

    function test_routerNotAllowed() public {
        MockRouter other = new MockRouter();
        vm.prank(agent);
        vm.expectRevert(SableAccount.RouterNotAllowed.selector);
        account.swap(address(other), address(usdc), 10e6, address(wmon), 1, "");
    }

    function test_divertedOutputReverts() public {
        router.setMode(MockRouter.Mode.Divert);
        uint256 out = uint256(10e6) * 1e12 * 100 / 3;
        vm.expectRevert(abi.encodeWithSelector(SableAccount.InsufficientOutput.selector, 0, out));
        _buy(agent, 10e6);
    }

    function test_underpaidOutputReverts() public {
        router.setMode(MockRouter.Mode.Underpay);
        vm.expectRevert();
        _buy(agent, 10e6);
    }

    function test_routerCannotPullMoreThanApproved() public {
        router.setMode(MockRouter.Mode.OverPull);
        vm.expectRevert();
        _buy(owner, 10e6);
    }

    function test_noAllowanceLeftAfterSwap() public {
        _buy(agent, 10e6);
        assertEq(usdc.allowance(address(account), address(router)), 0);
    }

    function test_zeroMinOutReverts() public {
        vm.prank(agent);
        vm.expectRevert(SableAccount.ZeroMinOut.selector);
        account.swap(address(router), address(usdc), 10e6, address(wmon), 0, "");
    }

    // ── fuzz: whatever the agent tries, one day never exceeds the daily cap ──

    function testFuzz_agentNeverExceedsDaily(uint32[12] memory amounts) public {
        uint256 spent;
        for (uint256 i; i < amounts.length; i++) {
            uint256 a = bound(amounts[i], 1, 60e6);
            try this.buyAsAgent(a) {
                spent += a;
            } catch {}
        }
        assertLe(spent, 200e6);
        assertEq(200e6 - spent, account.agentAllowance(address(usdc)));
    }

    function buyAsAgent(uint256 a) external {
        _buy(agent, a);
    }
}
