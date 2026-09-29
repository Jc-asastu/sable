// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SableAccount, IWMON} from "./SableAccount.sol";
import {TokenRegistry} from "./TokenRegistry.sol";

/// @notice Deploys one SableAccount clone per owner at a predictable address, so the app can
/// show a deposit address (and route cross-chain deposits to it) before the account exists.
/// Deploys the Shield TokenRegistry too, curated by the same admin.
/// While `open` is false only listed wallets can open an account (DECISIONS D10, D12).
contract SableAccountFactory is Ownable2Step {
    address public immutable implementation;
    TokenRegistry public immutable registry;
    bool public open;
    mapping(address => bool) public allowed;

    event AccountCreated(address indexed owner, address account);
    event AllowedSet(address indexed who, bool allowed);
    event Opened();

    error NotAllowed();
    error GasExceedsValue();
    error TransferFailed();

    constructor(address admin, IWMON wmon) Ownable(admin) {
        registry = new TokenRegistry(admin);
        implementation = address(new SableAccount(registry, wmon));
    }

    /// @notice The caller becomes the owner; the salt is the caller, so nobody can take your address.
    /// Onboarding in one transaction: any MON sent pays `agentGas` to the fast-trading key and
    /// deposits the rest into the new account (wrapped to WMON on arrival).
    function createAccount(address agent, address[] calldata routers, uint64 cooldown, uint256 agentGas)
        external
        payable
        returns (address account)
    {
        if (!open && !allowed[msg.sender]) revert NotAllowed();
        if (agentGas > msg.value || (agentGas != 0 && agent == address(0))) revert GasExceedsValue();
        account = Clones.cloneDeterministic(implementation, _salt(msg.sender));
        SableAccount(payable(account)).initialize(msg.sender, agent, routers, cooldown);
        emit AccountCreated(msg.sender, account);
        if (agentGas != 0) _send(agent, agentGas);
        if (msg.value > agentGas) _send(account, msg.value - agentGas);
    }

    function _send(address to, uint256 value) private {
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert TransferFailed();
    }

    function accountOf(address owner) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner));
    }

    function setAllowed(address[] calldata who, bool ok) external onlyOwner {
        for (uint256 i; i < who.length; i++) {
            allowed[who[i]] = ok;
            emit AllowedSet(who[i], ok);
        }
    }

    /// @notice One-way switch for the public launch.
    function openToEveryone() external onlyOwner {
        open = true;
        emit Opened();
    }

    function _salt(address owner) private pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }
}
