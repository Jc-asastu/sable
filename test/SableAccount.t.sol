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
            route, tokenIn, amountIn, tokenOut, minOut, gasFee, nextNonce++, block.timestamp + 1 hours, 0
        );
        bytes memory sig = _signSwap(address(account), agentKey, o, data);
        vm.prank(relayer);
        return account.swapWithSig(o, data, sig);
    }

    function _withdraw(address token, uint256 amount, address to, uint256 gasFee) internal {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(token, amount, to, gasFee, nextNonce++, block.timestamp + 1 hours, 0);
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
    function test_epochSwapReinstatement() public {
        testFuzz_epochRotationInvalidatesPendingOrders(false, 0);
    }

    function test_epochWithdrawalReinstatement() public {
        testFuzz_epochRotationInvalidatesPendingOrders(true, 0);
    }

    function testFuzz_epochRotationInvalidatesPendingOrders(bool withdrawal, uint8 mode) public {
        SableAccount.SwapOrder memory s = SableAccount.SwapOrder(
            address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, 0, block.timestamp + 1 hours, 0
        );
        SableAccount.WithdrawOrder memory w =
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours, 0);
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
        bytes memory sig = withdrawal
            ? _signWithdrawal(address(account), agentKey, w)
            : _signSwap(address(account), agentKey, s, data);
        bytes memory action = withdrawal
            ? abi.encodeCall(account.withdrawWithSig, (w, sig))
            : abi.encodeCall(account.swapWithSig, (s, data, sig));
        vm.startPrank(owner);
        if (mode % 3 == 0) account.setAgent(address(0));
        if (mode % 3 == 1) account.setAgent(stranger);
        account.setAgent(agent); // Includes direct same-key reset, not just remove/reinstall.
        vm.stopPrank();
        (bool ok,) = address(account).call(action);
        assertFalse(ok, "an earlier epoch must not revive when the same key returns");
        assertFalse(account.nonceUsed(0));
        bytes memory fresh =
            _epochAction(withdrawal, account.agentEpoch(), 0, block.timestamp + 1 hours, address(account));
        (ok,) = address(account).call(fresh);
        assertTrue(ok, "a fresh signature for the new epoch works");
    }

    function _epochAction(bool withdrawal, uint64 epoch, uint256 nonce, uint256 deadline, address domain)
        internal
        view
        returns (bytes memory)
    {
        if (withdrawal) {
            SableAccount.WithdrawOrder memory w =
                SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, nonce, deadline, epoch);
            return abi.encodeCall(account.withdrawWithSig, (w, _signWithdrawal(domain, agentKey, w)));
        }
        SableAccount.SwapOrder memory s = SableAccount.SwapOrder(
            address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, nonce, deadline, epoch
        );
        bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
        return abi.encodeCall(account.swapWithSig, (s, data, _signSwap(domain, agentKey, s, data)));
    }

    function _rejectAction(bytes memory action, bytes4 selector) internal {
        vm.prank(relayer);
        (bool ok, bytes memory error) = address(account).call(action);
        assertFalse(ok);
        assertEq(bytes4(error), selector);
    }

    function testFuzz_epochRejectsFutureAndDisabledOrDifferentAgent(bool withdrawal) public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory pending = _epochAction(withdrawal, 0, 0, deadline, address(account));
        vm.prank(owner);
        account.setAgent(address(0));
        _rejectAction(pending, SableAccount.NotAuthorized.selector);
        vm.prank(owner);
        account.setAgent(stranger);
        _rejectAction(_epochAction(withdrawal, 2, 0, deadline, address(account)), SableAccount.NotAuthorized.selector);
        assertFalse(account.nonceUsed(0));
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
        agentKey = 0xB0B;
        vm.prank(owner);
        account.setAgent(vm.addr(agentKey));
        _rejectAction(_epochAction(withdrawal, 4, 0, deadline, address(account)), SableAccount.NotAuthorized.selector);
        (bool ok,) = address(account).call(_epochAction(withdrawal, 3, 0, deadline, address(account)));
        assertTrue(ok, "new key and current epoch can execute");
    }

    function testFuzz_epochNonceIsGlobalAcrossOperationsAndRotations(bool withdrawal) public {
        bytes memory action = _epochAction(withdrawal, 0, 9, block.timestamp + 1 hours, address(account));
        (bool ok,) = address(account).call(action);
        assertTrue(ok);
        _rejectAction(action, SableAccount.NonceUsed.selector);
        vm.prank(owner);
        account.setAgent(agent);
        _rejectAction(
            _epochAction(!withdrawal, 1, 9, block.timestamp + 1 hours, address(account)),
            SableAccount.NonceUsed.selector
        );
        assertTrue(account.nonceUsed(9));
        (ok,) = address(account).call(_epochAction(!withdrawal, 1, 10, block.timestamp + 1 hours, address(account)));
        assertTrue(ok);
    }

    function testFuzz_epochDomainSeparation(bool withdrawal, uint8 mode) public {
        uint256 chain = block.chainid;
        if (mode % 3 == 0) vm.chainId(chain + 1);
        if (mode % 3 == 1) orderDomainVersion = "2";
        address domain = mode % 3 == 2 ? address(factory.implementation()) : address(account);
        bytes memory action = _epochAction(withdrawal, 0, 0, block.timestamp + 1 hours, domain);
        vm.chainId(chain);
        orderDomainVersion = "5";
        _rejectAction(action, SableAccount.NotAuthorized.selector);
        assertFalse(account.nonceUsed(0));
    }

    function testFuzz_epochDeadlineBoundary(bool withdrawal) public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory valid = _epochAction(withdrawal, 0, 0, deadline, address(account));
        bytes memory expired = _epochAction(withdrawal, 0, 1, deadline, address(account));
        vm.warp(deadline);
        (bool ok,) = address(account).call(valid);
        assertTrue(ok, "deadline is inclusive");
        vm.warp(deadline + 1);
        _rejectAction(expired, SableAccount.Expired.selector);
        assertFalse(account.nonceUsed(1));
    }

    function testFuzz_epochEveryOrderFieldIsSigned(bool withdrawal, uint8 field) public {
        bytes memory action;
        if (withdrawal) {
            SableAccount.WithdrawOrder memory w =
                SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours, 0);
            bytes memory sig = _signWithdrawal(address(account), agentKey, w);
            uint256 f = field % 7;
            if (f == 0) w.token = address(wmon);
            if (f == 1) w.amount++;
            if (f == 2) w.to = stranger;
            if (f == 3) w.gasFee++;
            if (f == 4) w.nonce++;
            if (f == 5) w.deadline++;
            if (f == 6) {
                vm.prank(owner);
                account.setAgent(agent);
                w.epoch++; // Now matches storage: rejection must come from the signed hash.
            }
            action = abi.encodeCall(account.withdrawWithSig, (w, sig));
        } else {
            SableAccount.SwapOrder memory s = SableAccount.SwapOrder(
                address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, 0, block.timestamp + 1 hours, 0
            );
            bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
            bytes memory sig = _signSwap(address(account), agentKey, s, data);
            uint256 f = field % 10;
            if (f == 0) s.router = stranger;
            if (f == 1) s.tokenIn = address(wmon);
            if (f == 2) s.amountIn++;
            if (f == 3) s.tokenOut = address(usdc);
            if (f == 4) s.minOut++;
            if (f == 5) s.gasFee++;
            if (f == 6) s.nonce++;
            if (f == 7) s.deadline++;
            if (f == 8) {
                vm.prank(owner);
                account.setAgent(agent);
                s.epoch++;
            }
            if (f == 9) data = hex"12345678";
            action = abi.encodeCall(account.swapWithSig, (s, data, sig));
        }
        _rejectAction(action, SableAccount.NotAuthorized.selector);
        assertFalse(account.nonceUsed(0));
        assertFalse(account.nonceUsed(1));
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
    }

    function testFuzz_epochFailedExecutionDoesNotConsumeNonce(bool withdrawal) public {
        bytes memory action = _epochAction(withdrawal, 0, 0, block.timestamp + 1 hours, address(account));
        if (withdrawal) {
            vm.prank(owner);
            account.withdraw(address(usdc), 1_000e6, owner);
        } else {
            vm.prank(owner);
            account.setRouter(address(router), false);
        }
        (bool ok,) = address(account).call(action);
        assertFalse(ok);
        assertFalse(account.nonceUsed(0));
        assertEq(account.agentAllowance(address(usdc)), 200e6);
        if (withdrawal) {
            usdc.mint(address(account), 1_000e6);
        } else {
            vm.prank(owner);
            account.setRouter(address(router), true);
        }
        (ok,) = address(account).call(action);
        assertTrue(ok, "same signature remains usable after reverted execution");
    }

    function testFuzz_epochRejectsLegacySchemaEvenAtEpochZero(bool withdrawal) public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory action;
        if (withdrawal) {
            bytes32 legacy = keccak256(
                "WithdrawOrder(address token,uint256 amount,address to,uint256 gasFee,uint256 nonce,uint256 deadline)"
            );
            bytes32 hash = keccak256(abi.encode(legacy, address(usdc), 1e6, owner, 0, 0, deadline));
            SableAccount.WithdrawOrder memory w =
                SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, deadline, 0);
            action = abi.encodeCall(account.withdrawWithSig, (w, _signOrder(address(account), agentKey, hash)));
        } else {
            bytes memory data = abi.encodeCall(MockRouter.swap, (address(usdc), 10e6, address(wmon), 1 ether));
            bytes32 legacy = keccak256(
                "SwapOrder(address router,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,uint256 gasFee,uint256 nonce,uint256 deadline,bytes32 dataHash)"
            );
            bytes32 hash = keccak256(
                abi.encode(
                    legacy,
                    address(router),
                    address(usdc),
                    10e6,
                    address(wmon),
                    1 ether,
                    0,
                    0,
                    deadline,
                    keccak256(data)
                )
            );
            SableAccount.SwapOrder memory s =
                SableAccount.SwapOrder(address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, 0, deadline, 0);
            action = abi.encodeCall(account.swapWithSig, (s, data, _signOrder(address(account), agentKey, hash)));
        }
        _rejectAction(action, SableAccount.NotAuthorized.selector);
        assertFalse(account.nonceUsed(0));
    }

    function test_signedSwapRejectsWrongSignerAndChangedCalldata() public {
        SableAccount.SwapOrder memory o = SableAccount.SwapOrder(
            address(router), address(usdc), 10e6, address(wmon), 1 ether, 0, 0, block.timestamp + 1 hours, 0
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
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours, 0);
        bytes memory sig = _signWithdrawal(address(factory.implementation()), agentKey, o);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.withdrawWithSig(o, sig);
        assertFalse(account.nonceUsed(0));
    }

    function test_signedWithdrawalNonceIsOneUse() public {
        SableAccount.WithdrawOrder memory o =
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours, 0);
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
            SableAccount.WithdrawOrder(address(usdc), 1e6, owner, 0, 0, block.timestamp + 1 hours, 0);
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

    function _registryCap(address token, uint128 perTrade, uint128 daily) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](1);
        caps[0] = TokenRegistry.Listing(perTrade, daily);
        if (daily == 0) registry.delist(tokens);
        else registry.list(tokens, caps);
    }

    function _assertCap(address token, uint128 perTrade, uint128 daily) internal view {
        SableAccount.Limit memory cap = account.capOf(token);
        assertEq(cap.perTrade, perTrade);
        assertEq(cap.daily, daily);
    }

    function _expectCapSwap(address tokenIn, uint256 amount, address tokenOut, bytes4 reason) internal {
        bytes memory data = abi.encodeCall(MockRouter.swap, (tokenIn, amount, tokenOut, 1));
        SableAccount.SwapOrder memory order = SableAccount.SwapOrder(
            address(router), tokenIn, amount, tokenOut, 1, 0, nextNonce++, block.timestamp + 1 hours, 0
        );
        bytes memory sig = _signSwap(address(account), agentKey, order, data);
        vm.prank(relayer);
        vm.expectRevert(reason);
        account.swapWithSig(order, data, sig);
        assertFalse(account.nonceUsed(order.nonce), "rejected policy preserves the nonce");
    }

    function test_registryCapsOverrideCannotListOrReviveEitherSide() public {
        for (uint256 i; i < 4; ++i) {
            MockToken token = new MockToken("OTHER", 6);
            token.mint(address(account), 10e6);
            bool input = i % 2 == 0;
            if (i >= 2) _registryCap(address(token), 50e6, 200e6);
            vm.prank(owner);
            account.setLimit(address(token), 50e6, 200e6);
            if (i >= 2) _registryCap(address(token), 0, 0);
            _assertCap(address(token), 0, 0);
            assertEq(account.agentAllowance(address(token)), 0);
            _expectCapSwap(
                input ? address(token) : address(usdc),
                1e6,
                input ? address(wmon) : address(token),
                SableAccount.TokenNotAllowed.selector
            );
            assertEq(token.balanceOf(address(account)), 10e6);
        }
    }

    function testFuzz_registryCapsComponentWiseMinimum(uint128 perTrade, uint128 daily) public {
        vm.prank(owner);
        account.setLimit(address(usdc), perTrade, daily);
        _assertCap(
            address(usdc), daily == 0 || perTrade > 50e6 ? 50e6 : perTrade, daily == 0 || daily > 200e6 ? 200e6 : daily
        );
    }

    function test_registryCapsOversizedAndMixedOverridesEnforceBothLimits() public {
        vm.prank(owner);
        account.setLimit(address(usdc), 100e6, 500e6);
        _expectCapSwap(address(usdc), 50e6 + 1, address(wmon), SableAccount.ExceedsPerTrade.selector);
        vm.prank(owner);
        account.setLimit(address(usdc), 100e6, 20e6);
        _assertCap(address(usdc), 50e6, 20e6);
        _buy(agent, 20e6);
        _expectCapSwap(address(usdc), 1, address(wmon), SableAccount.ExceedsDaily.selector);
        vm.prank(owner);
        account.setLimit(address(usdc), 10e6, 500e6);
        _assertCap(address(usdc), 10e6, 200e6);
        _expectCapSwap(address(usdc), 10e6 + 1, address(wmon), SableAccount.ExceedsPerTrade.selector);
        assertEq(account.agentAllowance(address(usdc)), 180e6, "override changes do not reset spend");
    }

    function test_registryCapsOversizedDailyCannotIncreaseSpending() public {
        vm.prank(owner);
        account.setLimit(address(usdc), 100e6, 500e6);
        for (uint256 i; i < 4; ++i) {
            _buy(agent, 50e6);
        }
        assertEq(account.agentAllowance(address(usdc)), 0);
        _expectCapSwap(address(usdc), 1, address(wmon), SableAccount.ExceedsDaily.selector);
    }

    function test_registryCapsReductionUsesExistingDailySpend() public {
        vm.warp(10 days + 1);
        vm.prank(owner);
        account.setLimit(address(usdc), 100e6, 500e6);
        _buy(agent, 40e6);
        _registryCap(address(usdc), 10e6, 50e6);
        _assertCap(address(usdc), 10e6, 50e6);
        assertEq(account.agentAllowance(address(usdc)), 10e6);
        _expectCapSwap(address(usdc), 10e6 + 1, address(wmon), SableAccount.ExceedsPerTrade.selector);
        _registryCap(address(usdc), 10e6, 30e6);
        assertEq(account.agentAllowance(address(usdc)), 0, "reduction below spend saturates allowance");
        _expectCapSwap(address(usdc), 1, address(wmon), SableAccount.ExceedsDaily.selector);
        (, uint192 spent) = account.spendOf(address(usdc));
        assertEq(spent, 40e6);
        vm.warp(11 days);
        assertEq(account.agentAllowance(address(usdc)), 30e6);
        _buy(agent, 10e6);
        assertEq(account.agentAllowance(address(usdc)), 20e6);
    }

    function test_registryCapsClearInheritsWholeListingAndZeroPerTradeRestricts() public {
        vm.prank(owner);
        account.setLimit(address(usdc), 0, 20e6);
        _assertCap(address(usdc), 0, 20e6);
        _expectCapSwap(address(usdc), 1, address(wmon), SableAccount.ExceedsPerTrade.selector);
        vm.prank(owner);
        account.setLimit(address(usdc), 1, 0);
        _assertCap(address(usdc), 50e6, 200e6);
        _buy(agent, 50e6);
        assertEq(account.agentAllowance(address(usdc)), 150e6);
        _registryCap(address(usdc), 0, 0);
        _assertCap(address(usdc), 0, 0);
        assertEq(account.agentAllowance(address(usdc)), 0);
    }

    function test_registryCapsDelistingKeepsOwnerExitAndRouterChecks() public {
        vm.startPrank(owner);
        account.setLimit(address(usdc), 100e6, 500e6);
        account.setLimit(address(wmon), 100e18, 500e18);
        vm.stopPrank();
        _registryCap(address(usdc), 0, 0);
        _registryCap(address(wmon), 0, 0);
        _expectCapSwap(address(usdc), 1e6, address(wmon), SableAccount.TokenNotAllowed.selector);
        assertGt(_buy(owner, 60e6), 0, "owner direct swap bypasses agent policy");
        vm.prank(owner);
        account.withdraw(address(usdc), 100e6, owner);
        assertEq(usdc.balanceOf(owner), 100e6);
        vm.prank(owner);
        account.setRouter(address(router), false);
        vm.expectRevert(SableAccount.RouterNotAllowed.selector);
        _buy(owner, 1e6);
        _registryCap(address(usdc), 50e6, 200e6);
        _registryCap(address(wmon), 100e18, 500e18);
        _expectCapSwap(address(usdc), 1e6, address(wmon), SableAccount.RouterNotAllowed.selector);
    }

    function test_registryCapsOnlyOwnerCanChangeLocalPolicy() public {
        address[2] memory callers = [agent, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(SableAccount.NotOwner.selector);
            account.setLimit(address(usdc), 1, 1);
            vm.prank(callers[i]);
            vm.expectRevert(SableAccount.NotOwner.selector);
            account.setRouter(address(router), false);
        }
        _assertCap(address(usdc), 50e6, 200e6);
        assertGt(_buy(agent, 10e6), 0);
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
