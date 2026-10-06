// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {IWMON} from "../src/SableAccount.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";

/// @notice Deploys the factory (and its Shield registry) with the broadcaster as admin, and lists
/// the quote assets every other listing trades against.
/// forge script script/Deploy.s.sol --rpc-url https://rpc.monad.xyz --account <keystore> --broadcast
/// Optional: SABLE_ALLOWED=0xabc...,0xdef...  (wallets allowed to open an account)
contract Deploy is Script {
    IWMON constant WMON = IWMON(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    function run() external returns (SableAccountFactory factory) {
        address[] memory allowed = vm.envOr("SABLE_ALLOWED", ",", new address[](0));

        vm.startBroadcast();
        (, address admin,) = vm.readCallers();
        factory = new SableAccountFactory(admin, WMON);
        if (allowed.length > 0) factory.setAllowed(allowed, true);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (USDC, address(WMON));
        TokenRegistry.Listing[] memory caps = new TokenRegistry.Listing[](2);
        caps[0] = TokenRegistry.Listing({perTrade: 25e6, daily: 100e6}); // 25 / 100 USDC
        caps[1] = TokenRegistry.Listing({perTrade: 1_000e18, daily: 4_000e18}); // ~ 25 / 100 USD of MON
        factory.registry().list(tokens, caps);
        factory.registry().setFee(30, admin); // 0.30% to the admin; capped on-chain at 1%
        vm.stopBroadcast();

        console2.log("admin", admin);
        console2.log("factory", address(factory));
        console2.log("registry", address(factory.registry()));
        console2.log("implementation", factory.implementation());
    }
}
