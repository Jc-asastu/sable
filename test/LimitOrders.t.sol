// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentOrders} from "./helpers/AgentOrders.sol";
import {SableAccount, IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {MockToken, MockWMON, MockVault} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// Relay depository stand-in: pulls the deposit like the real one and records it.
contract MockDepository {
    address public depositor;
    address public token;
    uint256 public amount;
    bytes32 public id;

    function depositErc20(address depositor_, address token_, uint256 amount_, bytes32 id_) external {
        IERC20(token_).transferFrom(msg.sender, address(this), amount_);
        (depositor, token, amount, id) = (depositor_, token_, amount_, id_);
    }
}

/// Limit orders that earn yield while they wait (DECISIONS D17).
contract LimitOrdersTest is AgentOrders {
    MockToken usdc;
    MockToken meme;
    MockWMON wmon;
    MockRouter router;
    MockVault vault;
    MockDepository depository;
    SableAccountFactory factory;
    TokenRegistry registry;
    SableAccount account;

    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE;
    address agent = vm.addr(agentKey);
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");
    uint32 constant SOLANA = 792703809;
    bytes32 constant SOL_WALLET = keccak256("owner's solana wallet");
    uint256 nonce;

    bytes32 private constant PLACE_TYPEHASH = keccak256(
        "PlaceOrder(address tokenIn,address vault,address tokenOut,uint64 deadline,uint32 destChainId,uint128 amountIn,uint128 minOut,uint128 destMinOut,bytes32 recipient,bytes32 destToken,uint256 nonce,uint256 sigDeadline,uint64 epoch)"
    );
    bytes32 private constant CANCEL_TYPEHASH = keccak256("CancelOrder(uint256 id,uint256 nonce,uint256 deadline,uint64 epoch)");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockToken("USDC", 6);
        meme = new MockToken("MEME", 18);
        wmon = new MockWMON();
        router = new MockRouter();
        factory = new SableAccountFactory(address(this), IWMON(address(wmon)));
        registry = factory.registry();
        vault = new MockVault(usdc);
        depository = new MockDepository();

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(meme));
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 500e6, daily: 1_000e6});
        caps[1] = TokenRegistry.Listing({perTrade: 1e30, daily: 1e30});
        registry.list(tokens, caps);
        registry.setFee(30, treasury);
        registry.setVault(address(vault), true);
        registry.setKeeper(keeper, true);
        registry.setRelayDepository(address(depository));
        factory.openToEveryone();

        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(agent, routers, 0, 0)));
        usdc.mint(address(account), 1_000e6);
    }

    // ── helpers ──

    function _local(uint128 amountIn, uint128 minOut) internal view returns (SableAccount.OrderParams memory p) {
        p.tokenIn = address(usdc);
        p.vault = address(vault);
        p.tokenOut = address(meme);
        p.deadline = uint64(block.timestamp + 7 days);
        p.amountIn = amountIn;
        p.minOut = minOut;
    }

    function _cross(uint128 amountIn) internal view returns (SableAccount.OrderParams memory p) {
        p.tokenIn = address(usdc);
        p.vault = address(vault);
        p.deadline = uint64(block.timestamp + 7 days);
        p.destChainId = SOLANA;
        p.amountIn = amountIn;
        p.destMinOut = 2e9; // 2 SOL
        p.recipient = SOL_WALLET;
        p.destToken = bytes32(0); // native SOL
    }

    function _placeAsOwner(SableAccount.OrderParams memory p) internal returns (uint256 id) {
        vm.prank(owner);
        id = account.placeOrder(p);
    }

    /// EIP-712 encodeData written out field by field, independent of the contract's abi.encode(struct).
    function _signPlace(SableAccount.OrderParams memory p, uint256 n, uint256 sigDeadline, uint64 epoch)
        internal
        view
        returns (bytes memory)
    {
        bytes memory head = abi.encode(PLACE_TYPEHASH, p.tokenIn, p.vault, p.tokenOut, p.deadline, p.destChainId);
        bytes memory tail = abi.encode(p.amountIn, p.minOut, p.destMinOut, p.recipient, p.destToken, n, sigDeadline, epoch);
        return _signOrder(address(account), agentKey, keccak256(bytes.concat(head, tail)));
    }

    function _placeAsAgent(SableAccount.OrderParams memory p) internal returns (uint256) {
        (uint256 n, uint256 sigDeadline, uint64 epoch, bytes memory sig) = _signed(p);
        vm.prank(stranger); // anyone relays it
        return account.placeOrderWithSig(p, n, sigDeadline, epoch, sig);
    }

    /// Signs first, so a test can expectRevert on the placement call itself.
    function _signed(SableAccount.OrderParams memory p) internal returns (uint256 n, uint256 dl, uint64 epoch, bytes memory sig) {
        (n, dl, epoch) = (++nonce, block.timestamp + 1 hours, account.agentEpoch());
        sig = _signPlace(p, n, dl, epoch);
    }

    function _expectAgentRevert(SableAccount.OrderParams memory p, bytes4 err) internal {
        (uint256 n, uint256 dl, uint64 epoch, bytes memory sig) = _signed(p);
        vm.expectRevert(err);
        account.placeOrderWithSig(p, n, dl, epoch, sig);
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

    function test_rejectsUnlistedVaultWrongAssetAndBadShapes() public {
        MockVault other = new MockVault(usdc);
        SableAccount.OrderParams memory p = _local(100e6, 1);
        p.vault = address(other);
        vm.prank(owner);
        vm.expectRevert(SableAccount.VaultNotAllowed.selector);
        account.placeOrder(p);

        MockVault wrongAsset = new MockVault(meme);
        registry.setVault(address(wrongAsset), true);
        p.vault = address(wrongAsset);
        vm.prank(owner);
        vm.expectRevert(SableAccount.VaultNotAllowed.selector);
        account.placeOrder(p);

        p = _local(100e6, 0); // no limit price
        vm.prank(owner);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.placeOrder(p);

        p = _local(100e6, 1);
        p.deadline = uint64(block.timestamp);
        vm.prank(owner);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.placeOrder(p);

        p = _cross(100e6);
        p.recipient = bytes32(0);
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
        uint256 out = account.fillOrder(id, address(router), _route(300e6, 1_000e18), 0);
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
        account.fillOrder(id, address(router), _route(300e6, 999e18), 0);
        assertEq(account.orderValue(id), 300e6, "the order keeps waiting");
    }

    function test_onlyKeepersFill() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        bytes memory data = _route(300e6, 1_000e18);
        for (uint256 i; i < 3; i++) {
            address who = [owner, agent, stranger][i];
            vm.prank(who);
            vm.expectRevert(SableAccount.NotAuthorized.selector);
            account.fillOrder(id, address(router), data, 0);
        }
    }

    function test_gasFeeComesFromTheOutputAndIsCapped() public {
        uint256 id = _placeAsOwner(_local(300e6, 1_000e18));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        account.fillOrder(id, address(router), _route(300e6, 1_200e18), 61e18); // > 5% of 1,200
        vm.prank(keeper);
        account.fillOrder(id, address(router), _route(300e6, 1_010e18), 10e18);
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
        account.fillOrder(id, address(router), _route(300e6, 1_000e18), 0);

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
        account.fillOrder(id, address(router), _route(300e6, 1_000e18), 0);
        assertEq(account.orderValue(id), 300e6, "still open, still earning");
        vault.setAvailable(type(uint256).max);
        vm.prank(keeper);
        account.fillOrder(id, address(router), _route(300e6, 1_000e18), 0);
    }

    function test_aVaultLossSpendsWhatIsLeftAndTheLimitStillBinds() public {
        uint256 id = _placeAsOwner(_local(300e6, 900e18));
        deal(address(usdc), address(vault), 270e6); // the vault lost 10%
        vm.prank(keeper);
        account.fillOrder(id, address(router), _route(270e6, 900e18), 0);
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
        bytes memory sig = _signOrder(address(account), agentKey, keccak256(abi.encode(CANCEL_TYPEHASH, id, n, dl, epoch)));
        vm.prank(stranger);
        account.cancelOrderWithSig(id, n, dl, epoch, sig);
        assertEq(usdc.balanceOf(address(account)), 1_000e6);
    }

    function test_agentOrdersRespectCapsAndTheShield() public {
        _expectAgentRevert(_local(501e6, 1), SableAccount.ExceedsPerTrade.selector);

        SableAccount.OrderParams memory p = _local(10e6, 1);
        p.tokenOut = address(new MockToken("RUG", 18)); // not Shield-listed
        _expectAgentRevert(p, SableAccount.TokenNotAllowed.selector);
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
        account.placeOrderWithSig(p, n, dl, epoch, sig);
    }

    // ── cross-chain fills (SOL on Solana) ──

    function test_agentCrossOrdersOnlyPayTheOwnerApprovedRecipient() public {
        _expectAgentRevert(_cross(300e6), SableAccount.NotAuthorized.selector); // no approved recipient yet

        vm.prank(stranger);
        vm.expectRevert(SableAccount.NotOwner.selector);
        account.setCrossRecipient(SOLANA, keccak256("attacker"));

        vm.prank(owner);
        account.setCrossRecipient(SOLANA, SOL_WALLET);
        SableAccount.OrderParams memory p = _cross(300e6);
        p.recipient = keccak256("attacker");
        _expectAgentRevert(p, SableAccount.NotAuthorized.selector);

        uint256 id = _placeAsAgent(_cross(300e6));
        assertEq(account.orderValue(id), 300e6);
    }

    function test_keeperFillsCrossOrdersThroughTheDepository() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        vault.accrue(3e6);
        bytes32 depositId = keccak256("relay request");
        uint256 fee = 300e6 * 30 / 10_000;
        vm.prank(keeper);
        account.fillCrossOrder(id, depositId, 1e6);
        assertEq(depository.amount(), 300e6 - fee - 1e6, "pays the solver what's left after fee and gas");
        assertEq(depository.depositor(), address(account));
        assertEq(depository.token(), address(usdc));
        assertEq(depository.id(), depositId);
        assertEq(usdc.balanceOf(treasury), fee + 1e6);
        assertApproxEqAbs(usdc.balanceOf(address(account)), 703e6, 1, "yield stays");
        assertEq(usdc.allowance(address(account), address(depository)), 0);
    }

    function test_crossFillsAreKeeperOnlyCappedAndNeedADepository() public {
        uint256 id = _placeAsOwner(_cross(300e6));
        vm.prank(owner);
        vm.expectRevert(SableAccount.NotAuthorized.selector);
        account.fillCrossOrder(id, bytes32(0), 0);

        vm.prank(keeper);
        vm.expectRevert(SableAccount.GasFeeTooHigh.selector);
        account.fillCrossOrder(id, bytes32(0), 20e6); // > 5%

        vm.prank(keeper);
        vm.expectRevert(SableAccount.BadOrder.selector);
        account.fillOrder(id, address(router), "", 0); // a cross order can't be filled locally

        registry.setRelayDepository(address(0));
        vm.prank(keeper);
        vm.expectRevert(SableAccount.NoDepository.selector);
        account.fillCrossOrder(id, bytes32(0), 0);
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
        registry.setRelayDepository(stranger);
        vm.stopPrank();
    }
}
