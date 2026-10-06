// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";

contract DeployTest is Test {
    function test_deployListsTestersAndStaysClosed() public {
        vm.setEnv(
            "SABLE_ALLOWED", "0x000000000000000000000000000000000000dEaD,0x000000000000000000000000000000000000bEEF"
        );
        SableAccountFactory factory = new Deploy().run();

        assertTrue(factory.allowed(address(0xdEaD)));
        assertTrue(factory.allowed(address(0xbEEF)));
        assertFalse(factory.open(), "guarded launch: closed until the admin opens it");
        assertTrue(factory.implementation() != address(0));
        assertTrue(factory.registry().isListed(0x754704Bc059F8C67012fEd69BC8A327a5aafb603), "USDC listed");
        assertEq(factory.registry().feeBps(), 30, "0.30% protocol fee");
        assertTrue(factory.registry().isListed(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A), "WMON listed");
    }
}
