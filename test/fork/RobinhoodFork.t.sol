// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SableAccountFactory} from "../../src/SableAccountFactory.sol";
import {SableAccount, IWMON} from "../../src/SableAccount.sol";
import {TokenRegistry} from "../../src/TokenRegistry.sol";

/// @notice Sable on Robinhood Chain, against real state: the Steakhouse USDG vault pays back on the spot,
/// and a hidden limit order "buy NVDA" waits in it and fills through the real KyberSwap router.
/// The route must be built for the account address, so the fill test runs in two steps:
///   1. ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --mc RobinhoodFork -vv
///   2. node scripts/kyber-fixture.mjs <account> 990000000 robinhood 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 \
///        0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec test/fixtures/kyber-usdg-nvda.json   then step 1 again
contract RobinhoodForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // the official Robinhood Stock Token
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd; // Morpho vault V2, Steakhouse
    address constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    string constant FIXTURE = "test/fixtures/kyber-usdg-nvda.json";

    SableAccountFactory factory;
    SableAccount account;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        factory = new SableAccountFactory(address(this), IWMON(WETH));
        address[] memory listed = new address[](1);
        listed[0] = owner;
        factory.setAllowed(listed, true);
        TokenRegistry registry = factory.registry();
        registry.setVault(STEAK_USDG, true);
        registry.setKeeper(keeper, true);

        address[] memory routers = new address[](1);
        routers[0] = KYBER_ROUTER;
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(makeAddr("agent"), routers, 0, 0)));
        console2.log("account", address(account));
    }

    function test_steakhouseUsdgPaysBackOnTheSpot() public {
        address me = makeAddr("depositor");
        deal(USDG, me, 1_000e6);
        vm.startPrank(me);
        IERC20(USDG).approve(STEAK_USDG, 1_000e6);
        uint256 shares = IERC4626(STEAK_USDG).deposit(1_000e6, me);
        uint256 back = IERC4626(STEAK_USDG).redeem(shares, me, me);
        vm.stopPrank();
        console2.log("USDG back from 1,000 (units)", back);
        assertGe(back, 999_990_000, "the vault pays back on the spot, in the same transaction");
    }

    function test_hiddenLimitOrderBuysNvdaWhileUsdgEarnsInSteakhouse() public {
        if (!vm.isFile(FIXTURE)) {
            console2.log("no fixture: node scripts/kyber-fixture.mjs", address(account), "(see the header)");
            vm.skip(true);
        }
        string memory json = vm.readFile(FIXTURE);
        if (vm.parseJsonAddress(json, ".account") != address(account)) {
            console2.log("fixture built for another account, rebuild for", address(account));
            vm.skip(true);
        }
        assertEq(vm.parseJsonAddress(json, ".router"), KYBER_ROUTER, "route uses the allowlisted router");
        uint256 minOut = vm.parseJsonUint(json, ".minOut");

        // The owner places "buy NVDA": 1,000 USDG wait in Steakhouse; only a commitment goes on-chain.
        deal(USDG, address(account), 1_000e6);
        SableAccount.Secret memory s = SableAccount.Secret({
            tokenOut: NVDA, destChainId: 0, minOut: uint128(minOut), destMinOut: 0, recipient: bytes32(0), destToken: bytes32(0), salt: keccak256("salt")
        });
        SableAccount.OrderParams memory p = SableAccount.OrderParams({
            tokenIn: USDG, vault: STEAK_USDG, deadline: uint64(block.timestamp + 7 days), amountIn: 1_000e6, commit: keccak256(abi.encode(s))
        });
        vm.prank(owner);
        uint256 id = account.placeOrder(p);
        assertEq(IERC20(USDG).balanceOf(address(account)), 0, "the USDG left for the vault");
        assertGt(account.orderValue(id), 999_000_000, "and is worth the deposit there");

        // The keeper reveals the secret and fills through Kyber at the limit or better.
        vm.prank(keeper);
        uint256 out = account.fillOrder(id, s, KYBER_ROUTER, vm.parseJsonBytes(json, ".data"), 0);
        console2.log("NVDA bought (units)", out);
        assertGe(out, minOut, "no worse than the limit");
        assertEq(IERC20(NVDA).balanceOf(address(account)), out, "the stock is in the account");
        assertEq(account.order(id).p.amountIn, 0, "order closed");
    }
}
