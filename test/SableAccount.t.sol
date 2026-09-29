// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {AgentOrders} from "./helpers/AgentOrders.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SableAccount, IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {MockToken, MockWMON} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract SableAccountTest is AgentOrders {
    MockToken usdc;
    MockWMON wmon;
    MockRouter router;
    SableAccountFactory factory;
    TokenRegistry registry;
    SableAccount account;

    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE; // Deterministic test key, never used outside this suite.
    address agent = vm.addr(agentKey);
    address relayer = makeAddr("relayer");
    uint256 nextNonce;
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
        if (by == agent) {
            return _submitSwap(address(router), tokenIn, amountIn, tokenOut, out, 0, data);
        }
        vm.prank(by);
        return account.swap(address(router), tokenIn, amountIn, tokenOut, out, data);
    }

    function _submitSwap(
        address route,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        uint256 gasFee,
        bytes memory data
    ) internal returns (uint256) {
        SableAccount.SwapOrder memory o = SableAccount.SwapOrder(
            route, tokenIn, amountIn, tokenOut, minOut, gasFee, nextNonce++, block.timestamp + 1 hours
        );
        bytes memory sig = _signSwap(address(account), agentKey, o, data);
        vm.prank(relayer);
        return account.swapWithSig(o, data, sig);
    }

    function _withdraw(address token, uint256 amount, address to, uint256 gasFee) internal {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(token, amount, to, gasFee, nextNonce++, block.timestamp + 1 hours);
        bytes memory sig = _signWithdrawal(address(account), agentKey, o);
        vm.prank(relayer);
        account.withdrawWithSig(o, sig);
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
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.withdraw(address(usdc), 1e6, agent); // the agent can't send funds to itself
        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
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
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.withdrawNative(1 ether, payable(agent));

        vm.prank(owner);
        account.withdrawNative(1 ether, payable(owner));
        assertEq(owner.balance, 1 ether);
    }

    function test_agentWithdrawsOnlyToOwner() public {
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        _withdraw(address(usdc), 1e6, agent, 0);
        _withdraw(address(usdc), 100e6, owner, 0);
        assertEq(usdc.balanceOf(owner), 100e6, "the fast key can return funds to the owner");

        vm.deal(address(wmon), 1 ether);
        _withdraw(address(0), 1 ether, owner, 0);
        assertEq(owner.balance, 1 ether);
    }

    function test_agentWithdrawsToApprovedPayoutOnly() public {
        address exchange = makeAddr("exchange");
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        _withdraw(address(usdc), 1e6, exchange, 0); // not approved yet

        vm.prank(agent);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setPayout(agent); // the key can't approve a destination for itself

        vm.prank(owner);
        account.setPayout(exchange);
        _withdraw(address(usdc), 50e6, exchange, 0);
        assertEq(usdc.balanceOf(exchange), 50e6, "instant withdrawal to the saved wallet");

        vm.prank(owner);
        account.setPayout(address(0));
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        _withdraw(address(usdc), 1e6, exchange, 0);
    }

    function test_directAgentCallsAreOwnerOnlyEvenWithSafeDestinations() public {
        vm.startPrank(agent);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.swap(address(router), address(usdc), 1e6, address(wmon), 1, "");
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.withdraw(address(usdc), 1e6, owner);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.withdrawNative(1 ether, payable(owner));
        vm.stopPrank();
    }

    function test_signedWithdrawalGasGoesToTreasuryNotSubmitter() public {
        address treasury = makeAddr("treasury");
        registry.setFee(0, treasury);
        _withdraw(address(usdc), 100e6, owner, 5e6); // exactly the 5% cap
        assertEq(usdc.balanceOf(owner), 100e6);
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.balanceOf(address(account)), 895e6);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(usdc.balanceOf(agent), 0);
    }

    function test_signedNativeWithdrawalPaysGasInWmon() public {
        address treasury = makeAddr("treasury");
        registry.setFee(0, treasury);
        vm.deal(address(wmon), 1 ether);
        uint256 before = wmon.balanceOf(address(account));
        _withdraw(address(0), 1 ether, owner, 0.05 ether);
        assertEq(owner.balance, 1 ether);
        assertEq(wmon.balanceOf(treasury), 0.05 ether);
        assertEq(wmon.balanceOf(address(account)), before - 1.05 ether);
        assertEq(relayer.balance, 0);
    }

    function test_signedWithdrawalRejectsExcessGasAndRollsBackNonce() public {
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        _withdraw(address(usdc), 100e6, owner, 5e6 + 1);
        assertFalse(account.nonceUsed(0));
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
        assertEq(usdc.balanceOf(owner), 0);
    }

    // Protocol fee

    function test_feeTakenFromInputAndRouteGetsTheRest() public {
        address treasury = makeAddr("treasury");
        registry.setFee(30, treasury); // 0.30%
        uint256 amountIn = 10e6;
        uint256 fee = amountIn * 30 / 10_000;
        // the route is built for the net amount; the router can't pull a unit more
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), amountIn - fee, address(wmon), 1e18));
        _submitSwap(address(router), address(usdc), amountIn, address(wmon), 1e18, 0, data);
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

    function test_signedSwapPaysGasFromOutputAndKeepsNetMinimum() public {
        address treasury = makeAddr("treasury");
        registry.setFee(30, treasury);
        uint256 before = wmon.balanceOf(address(account));
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 9_970_000, address(wmon), 1 ether));
        uint256 out = _submitSwap(address(router), address(usdc), 10e6, address(wmon), 0.95 ether, 0.05 ether, data);
        assertEq(out, 0.95 ether);
        assertEq(wmon.balanceOf(address(account)) - before, out);
        assertEq(wmon.balanceOf(treasury), 0.05 ether);
        assertEq(usdc.balanceOf(treasury), 30_000);
        assertEq(wmon.balanceOf(relayer), 0);
        assertEq(usdc.allowance(address(account), address(router)), 0);
    }

    function test_signedSwapRejectsExcessGasAndRollsBackTrade() public {
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        _submitSwap(address(router), address(usdc), 10e6, address(wmon), 0.9 ether, 0.05 ether + 1, data);
        assertFalse(account.nonceUsed(0));
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
        assertEq(account.agentAllowance(address(usdc)), 200e6);
        assertEq(usdc.allowance(address(account), address(router)), 0);
    }

    function test_signedSwapMinimumIncludesGas() public {
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
        vm.expectRevert(abi.encodeWithSelector(SableAccount.InsufficientOutput.selector, 1 ether, 1.01 ether));
        _submitSwap(address(router), address(usdc), 10e6, address(wmon), 1 ether, 0.01 ether, data);
        assertFalse(account.nonceUsed(0));
    }

    // Basic wire-format regressions; exhaustive adversarial lifecycle coverage is a separate unit.
    function test_signedSwapRejectsWrongSignerAndChangedCalldata() public {
        SableAccount.SwapOrder memory o = SableAccount.SwapOrder(
            address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, 0, block.timestamp + 1 hours
        );
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
        bytes memory sig = _signSwap(address(account), 0xBAD, o, data);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.swapWithSig(o, data, sig);

        sig = _signSwap(address(account), agentKey, o, data);
        bytes memory changedData = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 2 ether));
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.swapWithSig(o, changedData, sig);
        assertFalse(account.nonceUsed(0));
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
    }

    function test_signedWithdrawalRejectsWrongAccountDomain() public {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours);
        bytes memory sig = _signWithdrawal(address(factory.implementation()), agentKey, o);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdrawWithSig(o, sig);
        assertFalse(account.nonceUsed(0));
    }

    function test_signedWithdrawalNonceIsOneUse() public {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours);
        bytes memory sig = _signWithdrawal(address(account), agentKey, o);
        vm.prank(relayer);
        account.withdrawWithSig(o, sig);
        assertTrue(account.nonceUsed(0));
        vm.expectRevert(SableAccount.NonceUsed.selector);
        account.withdrawWithSig(o, sig);
        assertEq(usdc.balanceOf(owner), 1e6);
    }

    function test_signedWithdrawalExpiresAfterDeadline() public {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours);
        bytes memory sig = _signWithdrawal(address(account), agentKey, o);
        vm.warp(o.deadline + 1);
        vm.expectRevert(SableAccount.Expired.selector);
        account.withdrawWithSig(o, sig);
        assertFalse(account.nonceUsed(0));
        assertEq(usdc.balanceOf(owner), 0);
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
        vm.expectRevert(SableAccount.NotOwner.selector);
        _buy(stranger, 10e6);
        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setLimit(address(usdc), type(uint128).max, type(uint128).max);
    }

    // ── a bad route can't take funds ──

    function test_routerNotAllowed() public {
        MockRouter other = new MockRouter();
        vm.expectRevert(SableAccount.RouterNotAllowed.selector);
        _submitSwap(address(other), address(usdc), 10e6, address(wmon), 1, 0, "");
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
        vm.expectRevert(SableAccount.ZeroMinOut.selector);
        _submitSwap(address(router), address(usdc), 10e6, address(wmon), 0, 0, "");
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
