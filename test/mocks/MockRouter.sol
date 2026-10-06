// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "./Mocks.sol";

/// @notice Aggregator stand-in. `mode` makes it misbehave the ways a bad or compromised
/// route could: send the output elsewhere, pay less than quoted, or pull more than approved.
contract MockRouter {
    enum Mode {
        Honest,
        Divert,
        Underpay,
        OverPull
    }

    Mode public mode;
    address public constant THIEF = address(0xBAD);

    function setMode(Mode m) external {
        mode = m;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), mode == Mode.OverPull ? amountIn + 1 : amountIn);
        address to = mode == Mode.Divert ? THIEF : msg.sender;
        MockToken(tokenOut).mint(to, mode == Mode.Underpay ? amountOut / 2 : amountOut);
    }
}
