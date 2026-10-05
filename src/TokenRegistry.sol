// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title TokenRegistry (Sable Shield)
/// @notice Tokens an agent may trade, each with default agent caps in the token's own units.
/// A token only gets here after passing the off-chain Shield checks (liquidity, volume, pool age,
/// buy-and-sell round trip, contract permissions). Delisting stops agents from trading it at once.
contract TokenRegistry is Ownable2Step {
    struct Listing {
        uint128 perTrade; // agent cap per trade, token units; 0 = not listed
        uint128 daily; // agent cap per UTC day, token units
    }

    mapping(address => Listing) public listingOf;

    /// Protocol fee on every swap routed through a SableAccount, taken from the input token.
    uint16 public feeBps;
    address public feeRecipient;
    /// Hard ceiling on the fee: not even the owner can set more than 1%.
    uint16 public constant MAX_FEE_BPS = 100;

    /// ERC-4626 vaults a limit order's funds may earn in while they wait (DECISIONS D17).
    mapping(address => bool) public vaultAllowed;
    /// Keepers fill limit orders. A fill can't deliver less than the order's limit, locally (checked
    /// here) or cross-chain (Across enforces recipient and minimum), so a keeper only decides when.
    mapping(address => bool) public isKeeper;
    /// Across' SpokePool on this chain: cross-chain fills deposit here, and Across enforces the
    /// recipient and minimum output on-chain (audit C-1).
    address public acrossSpokePool;

    event Listed(address indexed token, uint128 perTrade, uint128 daily);
    event Delisted(address indexed token);
    event FeeSet(uint16 feeBps, address feeRecipient);
    event VaultSet(address indexed vault, bool allowed);
    event KeeperSet(address indexed keeper, bool allowed);
    event AcrossSpokePoolSet(address indexed pool);

    error LengthMismatch();
    error ZeroCap();
    error FeeTooHigh();

    constructor(address curator) Ownable(curator) {}

    /// @notice List or update tokens. Caps are refreshed as prices move so they stay near a
    /// fixed dollar amount per trade and per day.
    // ponytail: the owner curates by hand; add a dedicated keeper role when cap refreshes are automated.
    function list(address[] calldata tokens, Listing[] calldata caps) external onlyOwner {
        if (tokens.length != caps.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; i++) {
            if (caps[i].perTrade == 0 || caps[i].daily == 0) revert ZeroCap();
            listingOf[tokens[i]] = caps[i];
            emit Listed(tokens[i], caps[i].perTrade, caps[i].daily);
        }
    }

    function delist(address[] calldata tokens) external onlyOwner {
        for (uint256 i; i < tokens.length; i++) {
            delete listingOf[tokens[i]];
            emit Delisted(tokens[i]);
        }
    }

    function setFee(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS || (feeBps_ != 0 && feeRecipient_ == address(0))) revert FeeTooHigh();
        (feeBps, feeRecipient) = (feeBps_, feeRecipient_);
        emit FeeSet(feeBps_, feeRecipient_);
    }

    function setVault(address vault, bool allowed) external onlyOwner {
        vaultAllowed[vault] = allowed;
        emit VaultSet(vault, allowed);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setAcrossSpokePool(address pool) external onlyOwner {
        acrossSpokePool = pool;
        emit AcrossSpokePoolSet(pool);
    }

    /// @notice Fee and recipient in one read, for accounts and the app.
    function fee() external view returns (uint16, address) {
        return (feeBps, feeRecipient);
    }

    function isListed(address token) external view returns (bool) {
        return listingOf[token].daily != 0;
    }
}
