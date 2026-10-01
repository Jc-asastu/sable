// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SableAccount, IWMON} from "../../src/SableAccount.sol";
import {SableAccountFactory} from "../../src/SableAccountFactory.sol";

/// @notice Limit orders against the two real vaults users choose from (DECISIONS D17), on Monad
/// mainnet state. Skipped unless MONAD_RPC_URL is set:
/// MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc OrderVaultsFork -vv
contract OrderVaultsForkTest is Test {
    IERC20 constant USDC = IERC20(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
    IWMON constant WMON = IWMON(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);
    // Aave address book (AaveV3Monad.USDC_STATA_TOKEN) and the Euler Earn factory's Clearstar vault.
    IERC4626 constant AAVE = IERC4626(0xC554aFfE2f581F5E0811e0D42D484ECaC5c6B8e2);
    IERC4626 constant EULER = IERC4626(0xE1BcA19baA63894D374578320551633320436523);

    SableAccount account;
    address owner = makeAddr("owner");

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        SableAccountFactory factory = new SableAccountFactory(address(this), WMON);
        factory.registry().setVault(address(AAVE), true);
        factory.registry().setVault(address(EULER), true);
        factory.openToEveryone();
        vm.prank(owner);
        account = SableAccount(payable(factory.createAccount(address(0), new address[](0), 0, 0)));
        deal(address(USDC), address(account), 1_000e6);
    }

    function _roundTrip(IERC4626 vault, string memory name) internal {
        assertEq(vault.asset(), address(USDC), "vault asset is USDC");
        SableAccount.OrderParams memory p;
        p.tokenIn = address(USDC);
        p.vault = address(vault);
        p.tokenOut = address(WMON);
        p.deadline = uint64(block.timestamp + 60 days);
        p.amountIn = 300e6;
        p.minOut = 1;
        vm.prank(owner);
        uint256 id = account.placeOrder(p);
        assertApproxEqAbs(account.orderValue(id), 300e6, 2, "shares worth what went in");

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 days); // lending indexes follow time
        uint256 value = account.orderValue(id);
        console2.log(name, "300 USDC after 30 days:", value);
        assertGe(value + 2, 300e6, "a lending vault doesn't shrink over a quiet month");

        vm.prank(owner);
        account.cancelOrder(id);
        assertApproxEqAbs(USDC.balanceOf(address(account)), 700e6 + value, 2, "cancel returns principal and yield");
    }

    function test_aaveVault() public {
        _roundTrip(AAVE, "Aave");
    }

    function test_eulerVault() public {
        _roundTrip(EULER, "Euler Clearstar");
    }
}
