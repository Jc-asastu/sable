// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Which vaults can hold a limit order: an order needs an ERC-4626 of USDC that takes a deposit and
/// pays it back in the same transaction (the keeper redeems and swaps at once). For each candidate: deposit
/// 1,000 USDC, redeem it all at once, and log what came back. Skipped without the RPC variables:
/// MONAD_RPC_URL=… BASE_RPC_URL=… ARBITRUM_RPC_URL=… forge test --mc VaultCandidates -vv
contract VaultCandidatesTest is Test {
    address constant MONAD_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function _roundTrip(address vault, address usdc, string memory name) internal {
        address me = makeAddr(name);
        (bool okAsset, bytes memory a) = vault.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!okAsset || a.length < 32 || abi.decode(a, (address)) != usdc) {
            console2.log("NOT ERC-4626 OF USDC", name);
            return;
        }
        deal(usdc, me, 1_000e6);
        vm.startPrank(me);
        IERC20(usdc).approve(vault, 1_000e6);
        try IERC4626(vault).deposit(1_000e6, me) returns (uint256 shares) {
            try IERC4626(vault).redeem(shares, me, me) returns (uint256 back) {
                console2.log(back >= 990e6 ? "INSTANT  " : "LOSSY    ", name, back);
            } catch {
                console2.log("NO INSTANT EXIT", name);
            }
        } catch {
            console2.log("DEPOSIT REFUSED", name);
        }
        vm.stopPrank();
    }

    function test_monad() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        _roundTrip(0x1905EDDF5943ef6C92Ccf1469bd40fC2cB4A77b0, MONAD_USDC, "Euler eUSDC-12");
        _roundTrip(0x06047833d9aAC144f7F4e9B8234D2c7DDA1a8BAf, MONAD_USDC, "Euler eUSDC-17");
        _roundTrip(0xa3B64e2674463c98CbD21807055D8C1E008b6e79, MONAD_USDC, "Euler eUSDC-15");
    }

    function test_base() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        _roundTrip(0x944766f715b51967E56aFdE5f0Aa76cEaCc9E7f9, BASE_USDC, "Avantis vault");
        _roundTrip(0x3ec4a293Fb906DD2Cd440c20dECB250DeF141dF1, BASE_USDC, "Arcadia USDC pool");
        _roundTrip(0xC777031D50F632083Be7080e51E390709062263E, BASE_USDC, "Harvest 40 Acres");
        _roundTrip(0x904af90069D4485617D795bcEfb2E31E47E259cf, BASE_USDC, "Harvest IPOR");
        _roundTrip(0x0000000f2eB9f69274678c76222B35eEc7588a65, BASE_USDC, "yoUSD");
        _roundTrip(0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7, BASE_USDC, "yoUSD Edge");
        _roundTrip(0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F, BASE_USDC, "Steakhouse High Yield");
        _roundTrip(0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61, BASE_USDC, "Gauntlet USDC Prime");
        _roundTrip(0xef417a2512C5a41f69AE4e021648b69a7CdE5D03, BASE_USDC, "Yearn OG USDC");
        _roundTrip(0x7BfA7C4f149E7415b73bdeDfe609237e29CBF34A, BASE_USDC, "Spark USDC");
    }

    function test_arbitrum() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        _roundTrip(0x1A996cb54bb95462040408C06122D45D6Cdb6096, ARB_USDC, "Fluid fUSDC");
        _roundTrip(0x7CFaDFD5645B50bE87d546f42699d863648251ad, ARB_USDC, "Aave stataUSDCn");
        _roundTrip(0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA, ARB_USDC, "Steakhouse High Yield USDC");
    }
}
