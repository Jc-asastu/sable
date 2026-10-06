// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentOrders} from "./helpers/AgentOrders.sol";
import {SableAccount, IWMON, ISpokePool} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {MockToken, MockWMON, MockVault} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// Across SpokePool stand-in: pulls the input like the real one and records the deposit.
contract MockSpokePool {
    bytes32 public depositor;
    bytes32 public recipient;
    bytes32 public inputToken;
    bytes32 public outputToken;
    uint256 public inputAmount;
    uint256 public outputAmount;
    uint256 public destinationChainId;
    bytes32 public exclusiveRelayer;
    uint32 public fillDeadline;

    uint256 public messageLength = type(uint256).max;

    /// deposit(bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32,uint32,uint32,uint32,bytes),
    /// decoded in two halves (twelve arguments don't fit the stack in one function).
    fallback() external payable {
        require(bytes4(msg.data[:4]) == ISpokePool.deposit.selector, "not deposit");
        (depositor, recipient, inputToken, outputToken, inputAmount, outputAmount) =
            abi.decode(msg.data[4:196], (bytes32, bytes32, bytes32, bytes32, uint256, uint256));
        uint256 offset;
        (destinationChainId, exclusiveRelayer,, fillDeadline,, offset) =
            abi.decode(msg.data[196:388], (uint256, bytes32, uint32, uint32, uint32, uint256));
        require(offset == 12 * 32, "message offset");
        messageLength = abi.decode(msg.data[388:420], (uint256));
        IERC20(address(uint160(uint256(inputToken)))).transferFrom(msg.sender, address(this), inputAmount);
    }
}

/// A hostile vault an owner might be talked into: it pays back half and claims it paid everything.
contract LyingVault is MockVault {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256 assets) {
        assets = previewRedeem(shares);
        _burn(owner_, shares);
        IERC20(asset()).transfer(receiver, assets / 2);
    }
}

/// Limit orders that earn yield while they wait (DECISIONS D17).
contract LimitOrdersTest is AgentOrders {
    MockToken usdc;
    MockToken meme;
    MockWMON wmon;
    MockRouter router;
    MockVault vault;
    MockSpokePool pool;
    SableAccountFactory factory;
    TokenRegistry registry;
    SableAccount account;

    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE;
    address agent = vm.addr(agentKey);
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");
    uint64 constant SOLANA = 34268394551451; // Across' Solana chain id
    bytes32 constant SOL_WALLET = keccak256("owner's solana wallet");
    uint256 nonce;
    /// The hidden half of the order the last helper built; fills reveal it.
    SableAccount.Secret s;

    bytes32 private constant PLACE_TYPEHASH = keccak256(
        "PlaceOrder(address tokenIn,address vault,uint64 deadline,uint128 amountIn,bytes32 commit,uint256 gasFee,uint256 nonce,uint256 sigDeadline,uint64 epoch)"
    );
    bytes32 private constant CANCEL_TYPEHASH = keccak256("CancelOrder(uint256 id,uint256 gasFee,uint256 nonce,uint256 deadline,uint64 epoch)");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockToken("USDC", 6);
        meme = new MockToken("MEME", 18);
        wmon = new MockWMON();
        router = new MockRouter();
        factory = new SableAccountFactory(address(this), IWMON(address(wmon)));
        registry = factory.registry();
        vault = new MockVault(usdc);
        pool = new MockSpokePool();

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(meme));
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 500e6, daily: 1_000e6});
        caps[1] = TokenRegistry.Listing({perTrade: 1e30, daily: 1e30});
        registry.list(tokens, caps);
        registry.setFee(30, treasury);
        registry.setVault(address(vault), true);
        registry.setKeeper(keeper, true);
        registry.setAcrossSpokePool(address(pool));
        factory.openToEveryone();

        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(agent, routers, 0, 0)));
        usdc.mint(address(account), 1_000e6);
    }

    // ── helpers ──

    function _local(uint128 amountIn, uint128 minOut) internal returns (SableAccount.OrderParams memory) {
        delete s;
        (s.tokenOut, s.minOut, s.salt) = (address(meme), minOut, keccak256(abi.encode(++nonce)));
        return _public(amountIn);
    }

    function _cross(uint128 amountIn) internal returns (SableAccount.OrderParams memory) {
        delete s;
        (s.destChainId, s.destMinOut, s.recipient) = (SOLANA, 2e9, SOL_WALLET); // 2 native SOL
        s.salt = keccak256(abi.encode(++nonce));
        return _public(amountIn);
    }

    /// What goes on-chain: custody fields and the commitment to `s`. Call again after editing `s`.
    function _public(uint128 amountIn) internal view returns (SableAccount.OrderParams memory p) {
        (p.tokenIn, p.vault, p.deadline, p.amountIn) = (address(usdc), address(vault), uint64(block.timestamp + 7 days), amountIn);
        p.commit = keccak256(abi.encode(s));
    }

    function _placeAsOwner(SableAccount.OrderParams memory p) internal returns (uint256 id) {
        vm.prank(owner);
        id = account.placeOrder(p);
    }

    /// The relay gas fee the next agent placement signs (0 unless a test sets it).
    uint256 placeGas;

    /// EIP-712 encodeData written out field by field, independent of the contract's abi.encode(struct).
    function _signPlace(SableAccount.OrderParams memory p, uint256 n, uint256 sigDeadline, uint64 epoch)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encode(PLACE_TYPEHASH, p.tokenIn, p.vault, p.deadline, p.amountIn, p.commit, placeGas, n, sigDeadline, epoch));
        return _signOrder(address(account), agentKey, h);
    }

    function _placeAsAgent(SableAccount.OrderParams memory p) internal returns (uint256) {
        (uint256 n, uint256 sigDeadline, uint64 epoch, bytes memory sig) = _signed(p);
        vm.prank(stranger); // anyone relays it
        return account.placeOrderWithSig(p, placeGas, n, sigDeadline, epoch, sig);
    }

    /// Signs first, so a test can expectRevert on the placement call itself.
    function _signed(SableAccount.OrderParams memory p) internal returns (uint256 n, uint256 dl, uint64 epoch, bytes memory sig) {
        (n, dl, epoch) = (++nonce, block.timestamp + 1 hours, account.agentEpoch());
        sig = _signPlace(p, n, dl, epoch);
    }

    function _expectAgentRevert(SableAccount.OrderParams memory p, bytes4 err) internal {
        (uint256 n, uint256 dl, uint64 epoch, bytes memory sig) = _signed(p);
        vm.expectRevert(err);
        account.placeOrderWithSig(p, placeGas, n, dl, epoch, sig);
    }

    function _route(uint256 spend, uint256 out) internal view returns (bytes memory) {
        uint256 net = spend - spend * 30 / 10_000; // the account pays the 0.30% fee first
        return abi.encodeCall(MockRouter.swap, (address(usdc), net, address(meme), out));
    }

    // ── placing ──

    function test_placeMovesFundsIntoTheVault() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        assertEq(usdc.balanceOf(address(account)), 700e6, "300 USDC left the account balance");
        assertEq(usdc.balanceOf(address(vault)), 300e6, "and earn in the vault");
        assertEq(account.orderValue(id), 300e6);
        assertEq(account.order(id).shares, vault.balanceOf(address(account)));
        assertEq(vault.allowance(address(account), address(vault)), 0);
        assertEq(usdc.allowance(address(account), address(vault)), 0, "no leftover approval");
    }

    function test_yieldAccruesWhileWaiting() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vault.accrue(3e6); // 1% while the order waits
        assertApproxEqAbs(account.orderValue(id), 303e6, 1);
    }

    function test_theOwnerMayChooseAnyVaultButTheAgentOnlyAllowedOnes() public {
        MockVault other = new MockVault(usdc); // not in the registry
        SableAccount.OrderParams memory p = _local(100e6, 1);
        p.vault = address(other);
        uint256 id = _placeAsOwner(p);
        assertEq(account.orderValue(id), 100e6, "the owner's own pick holds the order");
        assertEq(usdc.allowance(address(account), address(other)), 0, "and gets no lasting approval");

        _local(100e6, 1);
        p = _public(100e6);
        p.vault = address(other);
        _expectAgentRevert(p, SableAccount.VaultNotAllowed.selector);
    }

    function test_aVaultThatLiesAboutWhatItPaidCantSpendTheRestOfTheAccount() public {
        SableAccount.OrderParams memory p = _local(300e6, 1);
        p.vault = address(new LyingVault(usdc));
        uint256 id = _placeAsOwner(p);
        assertEq(usdc.balanceOf(address(account)), 700e6, "700 USDC sit idle, outside the order");

        vm.prank(keeper);
        account.fillOrder(id, s, address(router), _route(150e6, 1), 0); // only 150 came back
        assertEq(usdc.balanceOf(treasury), 150e6 * 30 / 10_000, "the fee is on what came back");
        assertEq(usdc.balanceOf(address(account)), 700e6, "the idle USDC is untouched");

        p = _local(300e6, 1);
        p.vault = address(new LyingVault(usdc));
        id = _placeAsOwner(p);
        vm.prank(owner);
        account.cancelOrder(id);
        assertEq(usdc.balanceOf(address(account)), 550e6, "a cancel returns what really came back");
    }

    function test_rejectsWrongAssetAndBadShapes() public {
        SableAccount.OrderParams memory p = _local(100e6, 1);

        MockVault wrongAsset = new MockVault(meme);
        registry.setVault(address(wrongAsset), true);
        p.vault = address(wrongAsset);
        vm.prank(owner);
        vm.expectRevert(SableAccount.VaultNotAllowed.selector);
        account.placeOrder(p);

        p = _local(100e6, 1);
        p.deadline = uint64(block.timestamp);
        vm.prank(owner);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.placeOrder(p);

        p = _local(100e6, 1);
        p.commit = bytes32(0); // no hidden half
        vm.prank(owner);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.placeOrder(p);

        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.placeOrder(_local(100e6, 1));
    }

    // ── local fills: the limit price is enforced on-chain ──

    function test_keeperFillsAtTheLimitAndTheYieldStaysInTheAccount() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vault.accrue(3e6);
        vm.prank(keeper);
        uint256 out = account.fillOrder(id, s, address(router), _route(300e6, 1_000e18), 0);
        assertEq(out, 1_000e18);
        assertEq(meme.balanceOf(address(account)), 1_000e18, "bought at the limit");
        assertApproxEqAbs(usdc.balanceOf(address(account)), 703e6, 1, "yield above amountIn stays as USDC");
        assertEq(usdc.balanceOf(treasury), 300e6 * 30 / 10_000, "0.30% fee");
        assertEq(account.order(id).p.amountIn, 0, "order removed");
        assertEq(account.orderValue(id), 0);
    }

    function test_aWorseRouteThanTheLimitReverts() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SableAccount.InsufficientOutput.selector, 999e18, 1_000e18));
        account.fillOrder(id, s, address(router), _route(300e6, 999e18), 0);
        assertEq(account.orderValue(id), 300e6, "the order keeps waiting");
    }

    function test_onlyKeepersFill() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        bytes memory data = _route(300e6, 1_000e18);
        for (uint256 i; i < 3; i++) {
            address who = [owner, agent, stranger][i];
            vm.prank(who);
            vm.expectRevert(SableAccount.NotAuthorized.selector);
            account.fillOrder(id, s, address(router), data, 0);
        }
    }

    function test_gasFeeComesFromTheOutputAndIsCapped() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        account.fillOrder(id, s, address(router), _route(300e6, 1_200e18), 61e18); // > 5% of 1,200
        vm.prank(keeper);
        account.fillOrder(id, s, address(router), _route(300e6, 1_010e18), 10e18);
        assertEq(meme.balanceOf(treasury), 10e18, "gas reimbursed to the treasury, not the keeper");
        assertEq(meme.balanceOf(address(account)), 1_000e18, "the limit still holds after gas");
    }

    function test_expiredOrdersCantFillAndKeepersCanOnlyReturnThem() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.cancelOrder(id); // not expired yet

        vm.warp(block.timestamp + 8 days);
        vm.prank(keeper);
        vm.expectRevert(SableAccount.Expired.selector);
        account.fillOrder(id, s, address(router), _route(300e6, 1_000e18), 0);

        vm.prank(keeper);
        account.cancelOrder(id);
        assertEq(usdc.balanceOf(address(account)), 1_000e6, "funds back in the account");
    }

    function test_ownerCancelsAnyTimeWithYield() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vault.accrue(6e6);
        vm.prank(owner);
        account.cancelOrder(id);
        assertApproxEqAbs(usdc.balanceOf(address(account)), 1_006e6, 1);
        vm.prank(owner);
        vm.expectRevert(SableAccount.NoOrder.selector);
        account.cancelOrder(id);
    }

    function test_anIlliquidVaultDelaysTheFillWithoutLosingTheOrder() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vault.setAvailable(100e6); // lending market fully utilised
        vm.prank(keeper);
        vm.expectRevert();
        account.fillOrder(id, s, address(router), _route(300e6, 1_000e18), 0);
        assertEq(account.orderValue(id), 300e6, "still open, still earning");
        vault.setAvailable(type(uint256).max);
        vm.prank(keeper);
        account.fillOrder(id, s, address(router), _route(300e6, 1_000e18), 0);
    }

    function test_aVaultLossSpendsWhatIsLeftAndTheLimitStillBinds() public {
        uint256 id = _placeAsOwner(_local(300e6, 900e18));
        deal(address(usdc), address(vault), 270e6); // the vault lost 10%
        vm.prank(keeper);
        account.fillOrder(id, s, address(router), _route(270e6, 900e18), 0);
        assertEq(meme.balanceOf(address(account)), 900e18);
    }

    // ── agent-signed orders (fast key, relayed) ──

    function test_agentPlacesAndCancelsWithoutAWalletPopUp() public {
        uint256 id = _placeAsAgent(_local(300e6, 1_000e18));
        assertEq(account.orderValue(id), 300e6, "signature encoding matches the contract");
        assertEq(account.agentAllowance(address(usdc)), 700e6, "counts against the daily cap");

        uint256 n = ++nonce;
        uint256 dl = block.timestamp + 1 hours;
        uint64 epoch = account.agentEpoch();
        bytes memory sig = _signOrder(address(account), agentKey, keccak256(abi.encode(CANCEL_TYPEHASH, id, uint256(0), n, dl, epoch)));
        vm.prank(stranger);
        account.cancelOrderWithSig(id, 0, n, dl, epoch, sig);
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
    }

    function test_agentOrdersRespectCapsAndTheShield() public {
        _expectAgentRevert(_local(501e6, 1), SableAccount.ExceedsPerTrade.selector);

        _local(10e6, 1);
        s.tokenOut = address(new MockToken("RUG", 18)); // not Shield-listed: hidden, so it fails at the fill
        uint256 id = _placeAsAgent(_public(10e6));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.TokenNotAllowed.selector);
        account.fillOrder(id, s, address(router), "", 0);
    }

    function test_aRotatedKeyCantPlaceOrders() public {
        SableAccount.OrderParams memory p = _local(10e6, 1);
        uint256 n = ++nonce;
        uint256 dl = block.timestamp + 1 hours;
        uint64 epoch = account.agentEpoch();
        bytes memory sig = _signPlace(p, n, dl, epoch);
        vm.prank(owner);
        account.setAgent(agent); // same key, new epoch
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.placeOrderWithSig(p, placeGas, n, dl, epoch, sig);
    }

    // ── cross-chain fills (SOL on Solana) ──

    function test_agentCrossOrdersOnlyPayTheOwnerApprovedRecipient() public {
        uint256 id = _placeAsAgent(_cross(300e6));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.NotAuthorized.selector); // no approved recipient yet
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 0);

        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setCrossRecipient(SOLANA, keccak256("attacker"));

        vm.prank(owner);
        account.setCrossRecipient(SOLANA, SOL_WALLET);
        _cross(300e6);
        s.recipient = keccak256("attacker");
        uint256 bad = _placeAsAgent(_public(300e6));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.fillCrossOrder(bad, s, 2e9, uint32(block.timestamp), 0);

        _cross(300e6);
        uint256 good = _placeAsAgent(_public(300e6));
        vm.prank(keeper);
        account.fillCrossOrder(good, s, 2e9, uint32(block.timestamp), 0);
        assertEq(account.orderValue(good), 0, "filled to the approved wallet");
    }

    // ── hidden orders (D20) ──

    function test_theChainNeverShowsTheLimitUntilTheFill() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        SableAccount.LimitOrder memory o = account.order(id);
        assertEq(o.p.commit, keccak256(abi.encode(s)), "only the commitment is stored");
        assertEq(o.p.amountIn, 300e6);
    }

    function test_aWrongRevealCantFillAndTheOwnerStillGetsTheFundsBack() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        SableAccount.Secret memory lie = s;
        lie.minOut = 1; // a keeper trying a worse limit
        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillOrder(id, lie, address(router), _route(300e6, 1), 0);

        lie = s;
        lie.salt = bytes32(0);
        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillOrder(id, lie, address(router), _route(300e6, 1_000e18), 0);

        vm.prank(owner);
        account.cancelOrder(id); // no secret needed to get out
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
    }

    function test_aMalformedSecretIsRefusedAtTheFill() public {
        _local(300e6, 0); // no limit price
        uint256 id = _placeAsOwner(_public(300e6));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillOrder(id, s, address(router), _route(300e6, 1), 0);
    }

    function test_keeperFillsCrossOrdersThroughAcrossWithTheOwnersRecipient() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        vault.accrue(3e6);
        uint256 fee = 300e6 * 30 / 10_000;
        vm.prank(keeper);
        account.fillCrossOrder(id, s, 2.1e9, uint32(block.timestamp), 1e6); // a better quote than the 2 SOL limit
        assertEq(pool.inputAmount(), 300e6 - fee - 1e6, "deposits what's left after fee and gas");
        assertEq(pool.depositor(), bytes32(uint256(uint160(address(account)))), "refunds come back to the account");
        assertEq(pool.recipient(), SOL_WALLET, "the recipient is the owner's, from the revealed order");
        assertEq(pool.outputToken(), bytes32(0));
        assertEq(pool.outputAmount(), 2.1e9);
        assertEq(pool.destinationChainId(), SOLANA);
        assertEq(pool.exclusiveRelayer(), bytes32(0), "no relayer is favoured");
        assertEq(pool.fillDeadline(), block.timestamp + 1 hours);
        assertEq(usdc.balanceOf(treasury), fee + 1e6);
        assertApproxEqAbs(usdc.balanceOf(address(account)), 703e6, 1, "yield stays");
        assertEq(usdc.allowance(address(account), address(pool)), 0);
    }

    function test_aKeeperCantAskAcrossForLessThanTheLimit() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillCrossOrder(id, s, 2e9 - 1, uint32(block.timestamp), 0);
    }

    function test_crossFillsAreKeeperOnlyCappedAndNeedAPool() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        vm.prank(owner);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 0);

        vm.prank(keeper);
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 20e6); // > 5%

        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillOrder(id, s, address(router), "", 0); // a cross order can't be filled locally

        registry.setAcrossSpokePool(address(0));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.NoSpokePool.selector);
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 0);
    }

    // ── v5 safety controls (audit C-2, H-2, M-1) ──

    function test_theGuardianCanOnlyReduceRiskAndActsAtOnce() public {
        address guardian = makeAddr("guardian");
        registry.setGuardian(guardian);
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));

        vm.startPrank(guardian);
        registry.revokeKeeper(keeper);
        registry.setPaused(true, true);
        registry.disallowVault(address(vault));
        vm.expectRevert(TokenRegistry.NotGuardian.selector);
        registry.setPaused(false, true); // can't lift a pause
        vm.expectRevert();
        registry.setKeeper(guardian, true); // can't add a keeper
        vm.expectRevert();
        registry.setVault(address(vault), true); // can't allow a vault
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.fillOrder(id, s, address(router), _route(300e6, 1_000e18), 0);
        vm.prank(owner);
        vm.expectRevert(SableAccount.Paused.selector);
        account.placeOrder(_local(10e6, 1));
        vm.prank(owner);
        account.cancelOrder(id); // owners always get their money back
        assertEq(usdc.balanceOf(address(account)), 1_000e6);

        vm.prank(stranger);
        vm.expectRevert(TokenRegistry.NotGuardian.selector);
        registry.revokeKeeper(keeper);
    }

    function test_pausedCrossFillsWaitAndTooLargeCrossOrdersCantFill() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        registry.setPaused(false, true);
        vm.prank(keeper);
        vm.expectRevert(SableAccount.Paused.selector);
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 0);

        registry.setPaused(false, false);
        registry.setOrderBounds(address(usdc), 0, 100e6);
        vm.prank(keeper);
        vm.expectRevert(SableAccount.CrossTooLarge.selector);
        account.fillCrossOrder(id, s, 2e9, uint32(block.timestamp), 0);
    }

    function test_dustOrdersAreRefused() public {
        registry.setOrderBounds(address(usdc), 1e6, 0);
        vm.prank(owner);
        vm.expectRevert(SableAccount.OrderTooSmall.selector);
        account.placeOrder(_local(0.5e6, 1));
        _placeAsOwner(_local(1e6, 1));
    }

    function test_agentPlacementAndCancelRepayTheRelayerCapped() public {
        placeGas = 0.1e6;
        uint256 id = _placeAsAgent(_local(300e6, 1_000e18));
        assertEq(usdc.balanceOf(treasury), 0.1e6, "placement repaid the relayer");
        assertEq(account.orderValue(id), 300e6, "the order keeps its full amount");

        placeGas = 16e6; // > 5% of 300
        _expectAgentRevert(_local(300e6, 1_000e18), SableAccount.GasFeeTooHigh.selector);

        uint256 n = ++nonce;
        uint256 dl = block.timestamp + 1 hours;
        uint64 epoch = account.agentEpoch();
        bytes memory sig = _signOrder(address(account), agentKey, keccak256(abi.encode(CANCEL_TYPEHASH, id, uint256(0.2e6), n, dl, epoch)));
        vm.prank(stranger);
        account.cancelOrderWithSig(id, 0.2e6, n, dl, epoch, sig);
        assertEq(usdc.balanceOf(treasury), 0.3e6, "the cancel repaid it too");
    }

    function test_monSentBeforeTheAccountExistsIsWrappedOnCreation() public {
        address late = makeAddr("late");
        address predicted = factory.accountOf(late);
        vm.deal(predicted, 7 ether); // an exchange withdrawal to the deposit address, before opening
        vm.prank(late);
        address acct = factory.createAccount(address(0), new address[](0), 0, 0);
        assertEq(acct, predicted);
        assertEq(wmon.balanceOf(acct), 7 ether, "usable as WMON at once");
        assertEq(acct.balance, 0);
    }

    function test_registryControlsAreAdminOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        registry.setVault(stranger, true);
        vm.expectRevert();
        registry.setKeeper(stranger, true);
        vm.expectRevert();
        registry.setAcrossSpokePool(stranger);
        vm.stopPrank();
    }
}
