// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SableAccount, IWMON} from "../src/SableAccount.sol";
import {SableAccountFactory} from "../src/SableAccountFactory.sol";
import {MockWMON} from "./mocks/Mocks.sol";

/// Sponsored opening: the owner signs, the keeper (anyone) pays the gas.
contract CreateAccountForTest is Test {
    SableAccountFactory factory;
    uint256 ownerKey = 0xA11CE;
    address owner;
    address agent = address(0xA9E);
    address keeper = address(0xBEEF);
    address[] routers;

    bytes32 constant OPEN_TYPEHASH =
        keccak256("OpenAccount(address owner,address agent,bytes32 routers,uint64 cooldown,uint256 deadline)");

    function setUp() public {
        vm.warp(1_800_000_000);
        owner = vm.addr(ownerKey);
        factory = new SableAccountFactory(address(this), IWMON(address(new MockWMON())));
        factory.openToEveryone();
        routers.push(address(0x1234));
    }

    function _sign(uint256 key, address who, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(OPEN_TYPEHASH, who, agent, keccak256(abi.encodePacked(routers)), uint64(0), deadline));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("SableAccountFactory"), keccak256("1"), block.chainid, address(factory)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function test_keeperOpensTheOwnersAccount() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _sign(ownerKey, owner, deadline);
        vm.prank(keeper);
        address account = factory.createAccountFor(owner, agent, routers, 0, deadline, sig);
        assertEq(account, factory.accountOf(owner));
        assertEq(SableAccount(payable(account)).owner(), owner);
        assertEq(SableAccount(payable(account)).agent(), agent);
    }

    function test_rejectsAnExpiredSignature() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _sign(ownerKey, owner, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(SableAccountFactory.Expired.selector);
        factory.createAccountFor(owner, agent, routers, 0, deadline, sig);
    }

    function test_rejectsAnotherSignerOrChangedTerms() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory stranger = _sign(0xB0B, owner, deadline);
        vm.expectRevert(SableAccountFactory.BadSignature.selector);
        factory.createAccountFor(owner, agent, routers, 0, deadline, stranger);

        bytes memory sig = _sign(ownerKey, owner, deadline);
        vm.expectRevert(SableAccountFactory.BadSignature.selector);
        factory.createAccountFor(owner, address(0xBAD), routers, 0, deadline, sig); // swapped agent
    }

    function test_worksOnce() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _sign(ownerKey, owner, deadline);
        factory.createAccountFor(owner, agent, routers, 0, deadline, sig);
        vm.expectRevert();
        factory.createAccountFor(owner, agent, routers, 0, deadline, sig);
    }
}
