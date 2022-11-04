// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../SwapRouter.sol";

interface IOrderRouter {
    function dexes() external view returns (SwapRouter.Dex[] memory);

    function calculateSandboxFeeAmount(
        address tokenIn,
        address weth,
        uint128 amountIn,
        address usdc
    )
        external
        view
        returns (uint128 feeAmountRemaining, address quoteWethLiquidSwapPool);

    function _calculateV2SpotPrice(
        address token0,
        address token1,
        address _factory,
        bytes32 _initBytecode
    )
        external
        view
        returns (SwapRouter.SpotReserve memory spRes, address poolAddress);

    function _calculateFee(
        uint128 amountIn,
        address usdc,
        address weth
    ) external view returns (uint128);
}
