// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {SableTimelock} from "../src/admin/SableTimelock.sol";
import {MockWMON} from "./mocks/Mocks.sol";

/// The admin handover (audit C-2): the deployer configures, then gives the factory and the registry to
/// a 24h timelock whose only proposer and executor is the Safe. The guardian stays instant.
contract TimelockHandoverTest is Test {
    function test_theSafeTakesOverThroughA24hTimelockAndTheGuardianStaysInstant() public {
        address safe = makeAddr("safe");
        address guardian = makeAddr("guardian");
        SableAccountFactory factory = new SableAccountFactory(address(this), IWMON(address(new MockWMON())));
        TokenRegistry registry = factory.registry();
        registry.setGuardian(guardian); // configured by the deployer before the handover

        address[] memory roles = new address[](1);
        roles[0] = safe;
        SableTimelock timelock = new SableTimelock(1 days, roles, roles);
        factory.transferOwnership(address(timelock));
        registry.transferOwnership(address(timelock));

        address[] memory targets = new address[](2);
        (targets[0], targets[1]) = (address(factory), address(registry));
        uint256[] memory values = new uint256[](2);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("acceptOwnership()");
        calls[1] = abi.encodeWithSignature("acceptOwnership()");

        vm.prank(safe);
        timelock.scheduleBatch(targets, values, calls, bytes32(0), bytes32(0), 1 days);
        vm.prank(safe);
        vm.expectRevert(); // not before the delay
        timelock.executeBatch(targets, values, calls, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1 days);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // only the Safe executes
        timelock.executeBatch(targets, values, calls, bytes32(0), bytes32(0));
        vm.prank(safe);
        timelock.executeBatch(targets, values, calls, bytes32(0), bytes32(0));
        assertEq(factory.owner(), address(timelock));
        assertEq(registry.owner(), address(timelock));

        vm.expectRevert(); // the old admin has no power left
        registry.setKeeper(address(this), true);
        vm.prank(guardian);
        registry.setPaused(true, true); // instant, no timelock
        assertTrue(registry.crossFillsPaused());
    }
}
