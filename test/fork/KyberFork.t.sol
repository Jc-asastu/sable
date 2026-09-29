// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {AgentOrders} from "../helpers/AgentOrders.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SableAccountFactory} from "../../src/SableAccountFactory.sol";
import {SableAccount, IWMON} from "../../src/SableAccount.sol";
import {TokenRegistry} from "../../src/TokenRegistry.sol";

/// @notice An agent swap through the real KyberSwap router on a Monad mainnet fork, with the
/// account's limits active. Two steps, because the route must be built for the account address:
///   1. MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc KyberFork -vv   (prints the account)
///   2. node scripts/kyber-fixture.mjs <account>   then run step 1 again
contract KyberForkTest is AgentOrders {
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    string constant FIXTURE = "test/fixtures/kyber-usdc-wmon.json";

    SableAccount account;
    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE; // Mock signer, used only on the local fork.
    address agent = vm.addr(agentKey);

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        SableAccountFactory factory = new SableAccountFactory(address(this), IWMON(WMON));
        address[] memory listed = new address[](1);
        listed[0] = owner;
        factory.setAllowed(listed, true);

        address[] memory routers = new address[](1);
        routers[0] = KYBER_ROUTER;
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (USDC, WMON);
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 5e6, daily: 20e6});
        caps[1] = TokenRegistry.Listing({perTrade: 500e18, daily: 2_000e18});
        factory.registry().list(tokens, caps);

        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(agent, routers, 0, 0)));
        console2.log("account", address(account));
    }

    function test_nativeMonDepositWrapsIntoRealWmon() public {
        vm.deal(owner, 3 ether);
        vm.prank(owner);
        (bool ok,) = address(account).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(IERC20(WMON).balanceOf(address(account)), 3 ether, "plain MON send lands as WMON");
    }

    function test_agentSwapsThroughRealKyberRouter() public {
        if (!vm.isFile(FIXTURE)) {
            console2.log("no fixture: node scripts/kyber-fixture.mjs", address(account));
            vm.skip(true);
        }
        string memory json = vm.readFile(FIXTURE);
        if (vm.parseJsonAddress(json, ".account") != address(account)) {
            console2.log("fixture built for another account, rebuild for", address(account));
            vm.skip(true);
        }
        uint256 amountIn = vm.parseJsonUint(json, ".amountIn");
        uint256 minOut = vm.parseJsonUint(json, ".minOut");
        assertEq(vm.parseJsonAddress(json, ".router"), KYBER_ROUTER, "route uses the allowlisted router");

        deal(USDC, address(account), 10e6);
        bytes memory data = vm.parseJsonBytes(json, ".data");
        SableAccount.SwapOrder memory o =
            SableAccount.SwapOrder(KYBER_ROUTER, USDC, amountIn, WMON, minOut, 0, 0, block.timestamp + 1 hours, 0);
        bytes memory sig = _signSwap(address(account), agentKey, o, data);
        vm.prank(makeAddr("relayer"));
        uint256 out = account.swapWithSig(o, data, sig);

        console2.log("WMON received (units)", out);
        assertGe(out, minOut);
        assertEq(IERC20(USDC).balanceOf(address(account)), 10e6 - amountIn, "spent exactly amountIn");
        assertEq(IERC20(USDC).allowance(address(account), KYBER_ROUTER), 0, "no allowance left");
        assertEq(account.agentAllowance(USDC), 20e6 - amountIn, "limit accounted");
    }
}
