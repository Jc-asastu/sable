// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

// The 24h timelock that owns the factory and the registry; its proposer and executor is the Safe (audit C-2).
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract SableTimelock is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {}
}
