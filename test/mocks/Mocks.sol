// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice WMON stand-in: wraps native MON 1:1, like WETH9.
contract MockWMON is MockToken {
    constructor() MockToken("WMON", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native send failed");
    }
}

/// @notice Lending vault stand-in. `accrue` simulates interest, `setAvailable` simulates a
/// fully utilized market where only part of the deposits can be withdrawn.
contract MockVault is ERC4626 {
    uint256 public available = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("mVault", "mV") {}

    function accrue(uint256 amount) external {
        MockToken(asset()).mint(address(this), amount);
    }

    function setAvailable(uint256 a) external {
        available = a;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 m = super.maxWithdraw(owner);
        return m < available ? m : available;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 m = super.maxRedeem(owner);
        uint256 a = convertToShares(available == type(uint256).max ? type(uint128).max : available);
        return m < a ? m : a;
    }
}
