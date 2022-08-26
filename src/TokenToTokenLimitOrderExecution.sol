// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../lib/interfaces/token/IERC20.sol";
import "../lib/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import "../lib/interfaces/uniswap-v2/IUniswapV2Factory.sol";
import "../lib/interfaces/uniswap-v3/IUniswapV3Factory.sol";
import "../lib/interfaces/uniswap-v3/IUniswapV3Pool.sol";
import "../lib/libraries/ConveyorMath.sol";
import "../lib/libraries/Uniswap/SqrtPriceMath.sol";
import "./OrderBook.sol";
import "./OrderRouter.sol";
import "./ConveyorErrors.sol";
import "../lib/libraries/Uniswap/FullMath.sol";
import "../lib/interfaces/token/IWETH.sol";
import "../lib/interfaces/uniswap-v3/IQuoter.sol";
import "../lib/libraries/ConveyorTickMath.sol";
import "./ILimitOrderBatcher.sol";

/// @title OrderRouter
/// @author LeytonTaylor, 0xKitsune, Conveyor Labs
/// @notice Limit Order contract to execute existing limit orders within the OrderBook contract.
contract TokenToTokenExecution is OrderRouter {
    // ========================================= Modifiers =============================================

    ///@notice Conveyor funds balance in the contract.
    uint256 conveyorBalance;

    // ========================================= Constants  =============================================

    ///@notice The wrapped native token address for the chain.
    address immutable WETH;

    ///@notice The USD pegged token address for the chain.
    address immutable USDC;

    ///@notice TODO:
    address immutable LIMIT_ORDER_BATCHER;

    ///@notice The execution cost of fufilling a standard ERC20 swap from tokenIn to tokenOut
    uint256 immutable ORDER_EXECUTION_GAS_COST;

    ///@notice IQuoter instance to quote the amountOut for a given amountIn on a UniV3 pool.
    IQuoter immutable iQuoter;

    ///@notice State variable to track the amount of gas initally alloted during executeOrders.
    uint256 initialTxGas;

    TokenToTokenBatchOrder[] batchOrders;

    // ========================================= Constructor =============================================

    ///@param _weth - Address of the wrapped native token for the chain.
    ///@param _usdc - Address of the USD pegged token for the chain.
    ///@param _quoterAddress - Address for the IQuoter instance.
    //TODO: limit order batcher
    ///@param _executionCost - The execution cost of fufilling a standard ERC20 swap from tokenIn to tokenOut
    ///@param _initByteCodes - Array of initBytecodes required to calculate pair addresses for each DEX.
    ///@param _dexFactories - Array of DEX factory addresses to be added to the system.
    ///@param _isUniV2 - Array indicating if a DEX factory passed in during initialization is a UniV2 compatiable DEX.
    ///@param _alphaXDivergenceThreshold - Threshold between UniV3 and UniV2 spot price that determines if maxBeaconReward should be used.
    constructor(
        address _weth,
        address _usdc,
        address _quoterAddress,
        address _limitOrderBatcher,
        uint256 _executionCost,
        bytes32[] memory _initByteCodes,
        address[] memory _dexFactories,
        bool[] memory _isUniV2,
        uint256 _alphaXDivergenceThreshold
    )
        OrderRouter(
            _initByteCodes,
            _dexFactories,
            _isUniV2,
            _alphaXDivergenceThreshold
        )
    {
        iQuoter = IQuoter(_quoterAddress);
        WETH = _weth;
        USDC = _usdc;
        LIMIT_ORDER_BATCHER = _limitOrderBatcher;
        ORDER_EXECUTION_GAS_COST = _executionCost;
    }

    // ========================================= FUNCTIONS =============================================

    // ==================== Order Execution Functions =========================

    ///@notice Transfer the order quantity to the contract.
    ///@return success - Boolean to indicate if the transfer was successful.
    function transferTokensToContract(OrderBook.Order memory order)
        internal
        returns (bool success)
    {
        try
            IERC20(order.tokenIn).transferFrom(
                order.owner,
                address(this),
                order.quantity
            )
        {} catch {
            ///@notice Revert on token transfer failure.
            revert TokenTransferFailed(order.orderId);
        }
        return true;
    }

    ///@notice Function to execute an array of TokenToToken orders
    ///@param orders - Array of orders to be executed.
    function executeTokenToTokenOrders(OrderBook.Order[] memory orders)
        external
    {
        ///@notice Get all execution prices.
        (
            TokenToTokenExecutionPrice[] memory executionPrices,
            uint128 maxBeaconReward
        ) = ILimitOrderBatcher(LIMIT_ORDER_BATCHER).initializeTokenToTokenExecutionPrices(orders);

        //TODO: external call to the lib and then if everything goes through, then transfer all tokes to the current contract context
        ///@notice Batch the orders into optimized quantities to result in the best execution price and gas cost for each order.
        TokenToTokenBatchOrder[]
            memory tokenToTokenBatchOrders = ILimitOrderBatcher(
                LIMIT_ORDER_BATCHER
            ).batchTokenToTokenOrders(orders, executionPrices);

        ///@notice Execute the batches of orders.
        _executeTokenToTokenBatchOrders(
            tokenToTokenBatchOrders,
            maxBeaconReward
        );
    }

    ///@notice Function to execute an array of TokenToToken orders
    ///@param orders - Array of orders to be executed.
    function executeTokenToTokenOrderSingle(OrderBook.Order[] memory orders)
        external
    {
        ///@notice Get all execution prices.
        (
            TokenToTokenExecutionPrice[] memory executionPrices,
            uint128 maxBeaconReward
        ) = ILimitOrderBatcher(LIMIT_ORDER_BATCHER).initializeTokenToTokenExecutionPrices(orders);

        uint256 bestPriceIndex = ILimitOrderBatcher(
                LIMIT_ORDER_BATCHER
            ).findBestTokenToTokenExecutionPrice(
            executionPrices,
            orders[0].buy
        );

        ///@notice Execute the batches of orders.
        _executeTokenToTokenSingle(
            orders[0],
            maxBeaconReward,
            executionPrices[bestPriceIndex]
        );
    }

    ///@notice Function to execute token to token batch orders.
    ///@param tokenToTokenBatchOrders - Array of token to token batch orders.
    ///@param maxBeaconReward - Max beacon reward for the batch.
    function _executeTokenToTokenBatchOrders(
        TokenToTokenBatchOrder[] memory tokenToTokenBatchOrders,
        uint128 maxBeaconReward
    ) internal {
        uint256 totalBeaconReward;

        ///@notice For each batch order in the array.
        for (uint256 i = 0; i < tokenToTokenBatchOrders.length; ) {
            TokenToTokenBatchOrder memory batch = tokenToTokenBatchOrders[i];

            ///@notice Execute the batch order
            (
                uint256 amountOut,
                uint256 beaconReward
            ) = _executeTokenToTokenBatch(batch);

            ///@notice aAd the beacon reward to the totalBeaconReward
            totalBeaconReward += beaconReward;

            ///@notice Calculate the amountOut owed to each order owner in the batch.
            uint256[] memory ownerShares = batch.ownerShares;
            uint256 amountIn = batch.amountIn;
            uint256 batchOrderLength = batch.batchLength;
            for (uint256 j = 0; j < batchOrderLength; ) {
                ///@notice Calculate how much to pay each user from the shares they own
                uint128 orderShare = ConveyorMath.divUI(
                    ownerShares[j],
                    amountIn
                );

                ///@notice Calculate the orderPayout to the order owner.
                uint256 orderPayout = ConveyorMath.mul64I(
                    orderShare,
                    amountOut
                );

                ///@notice Send the order payout to the order owner.
                ///FIXME: Fix
                safeTransferETH(batch.batchOwners[j], orderPayout);

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        ///@notice Adjust the totalBeaconReward according to the maxBeaconReward.
        totalBeaconReward = totalBeaconReward < maxBeaconReward
            ? totalBeaconReward
            : maxBeaconReward;

        ///@notice Unwrap the total reward.
        IWETH(WETH).withdraw(totalBeaconReward);

        ///@notice Send the off-chain executor their reward.
        safeTransferETH(tx.origin, totalBeaconReward);
    }

    ///@notice Function to execute a single Token To Token order.
    ///@param order - The order to be executed.
    ///@param maxBeaconReward - The maximum beacon reward.
    ///@param executionPrice - The best priced TokenToTokenExecutionPrice to execute the order on.
    function _executeTokenToTokenSingle(
        OrderBook.Order memory order,
        uint128 maxBeaconReward,
        TokenToTokenExecutionPrice memory executionPrice
    ) internal {
        ///@notice Cache the owner address in memory.
        address owner = order.owner;

        ///@notice Create an array of orderOwners of length 1 and set the owner to the 0th index.
        address[] memory orderOwners = new address[](1);
        orderOwners[0] = owner;

        ///@notice Execute the order.
        (uint256 amountOut, uint256 beaconReward) = _executeTokenToTokenOrder(
            order,
            executionPrice
        );

        ///@notice Send the order payout to the order owner.
        IERC20(order.tokenOut).transfer(owner, amountOut);

        ///@notice Adjust the beaconReward according to the maxBeaconReward.
        beaconReward = beaconReward < maxBeaconReward
            ? beaconReward
            : maxBeaconReward;

        ///@notice Send the off-chain executor their reward.
        IWETH(WETH).withdraw(beaconReward);

        ///@notice Transfer the unwrapped ether to the tx origin.
        safeTransferETH(tx.origin, beaconReward);
    }

    ///@notice Function to execute a swap from TokenToWeth for an order.
    ///@param executionPrice - The best priced TokenToTokenExecutionPrice for the order to be executed on.
    ///@param order - The order to be executed.
    ///@return amountOutWeth - The amountOut in Weth after the swap.
    function _executeSwapTokenToWethOrder(
        TokenToTokenExecutionPrice memory executionPrice,
        OrderBook.Order memory order
    ) internal returns (uint128 amountOutWeth) {
        ///@notice Cache the liquidity pool address.
        address lpAddressAToWeth = executionPrice.lpAddressAToWeth;

        ///@notice Cache the order Quantity.
        uint256 orderQuantity = order.quantity;

        uint24 feeIn = order.feeIn;
        address tokenIn = order.tokenIn;

        ///@notice Calculate the amountOutMin for the tokenA to Weth swap.
        uint256 batchAmountOutMinAToWeth = ILimitOrderBatcher(LIMIT_ORDER_BATCHER).calculateAmountOutMinAToWeth(
            lpAddressAToWeth,
            orderQuantity,
            order.taxIn,
            feeIn,
            tokenIn
        );

        ///@notice Swap from tokenA to Weth.
        amountOutWeth = uint128(
            _swap(
                tokenIn,
                WETH,
                lpAddressAToWeth,
                feeIn,
                order.quantity,
                batchAmountOutMinAToWeth,
                address(this),
                order.owner
            )
        );

        ///@notice Take out fees from the amountOut.
        uint128 protocolFee = _calculateFee(amountOutWeth, USDC, WETH);

        ///@notice Calculate the conveyorReward and executor reward.
        (uint128 conveyorReward, uint128 beaconReward) = _calculateReward(
            protocolFee,
            amountOutWeth
        );

        ///@notice Increment the conveyor protocol's balance of ether in the contract by the conveyorReward.
        conveyorBalance += conveyorReward;

        ///@notice Get the AmountIn for weth to tokenB.
        amountOutWeth = amountOutWeth - (beaconReward + conveyorReward);
    }

    ///@notice Function to execute a single Token To Token order.
    ///@param order - The order to be executed.
    ///@param executionPrice - The best priced TokenToTokenExecution price to execute the order on.
    function _executeTokenToTokenOrder(
        OrderBook.Order memory order,
        TokenToTokenExecutionPrice memory executionPrice
    ) internal returns (uint256, uint256) {
        ///@notice Initialize variables to prevent stack too deep.
        uint256 amountInWethToB;
        uint128 conveyorReward;
        uint128 beaconReward;

        ///@notice Scope to prevent stack too deep.
        {
            ///@notice If the tokenIn is not weth.
            if (order.tokenIn != WETH) {
                amountInWethToB = _executeSwapTokenToWethOrder(
                    executionPrice,
                    order
                );
                if (amountInWethToB == 0) {
                    revert InsufficientOutputAmount();
                }
            } else {
                ///@notice Transfer the TokenIn to the contract.
                transferTokensToContract(order);

                uint256 amountIn = order.quantity;
                ///@notice Take out fees from the batch amountIn since token0 is weth.
                uint128 protocolFee = _calculateFee(
                    uint128(amountIn),
                    USDC,
                    WETH
                );

                ///@notice Calculate the conveyorReward and the off-chain logic executor reward.
                (conveyorReward, beaconReward) = _calculateReward(
                    protocolFee,
                    uint128(amountIn)
                );

                ///@notice Increment the conveyor balance by the conveyor reward.
                conveyorBalance += conveyorReward;

                ///@notice Get the amountIn for the Weth to tokenB swap.
                amountInWethToB = amountIn - (beaconReward + conveyorReward);
            }
        }

        ///@notice Swap Weth for tokenB.
        uint256 amountOutInB = _swap(
            WETH,
            order.tokenOut,
            executionPrice.lpAddressWethToB,
            order.feeOut,
            amountInWethToB,
            order.amountOutMin,
            order.owner,
            address(this)
        );

        if (amountOutInB == 0) {
            revert InsufficientOutputAmount();
        }

        return (amountOutInB, uint256(beaconReward));
    }

    ///@notice Function to execute a token to token batch
    ///@param batch - The token to token batch to execute.
    ///@return amountOut - The amount out recevied from the swap.
    ///@return beaconReward - Compensation reward amount to be sent to the off-chain logic executor.
    function _executeTokenToTokenBatch(TokenToTokenBatchOrder memory batch)
        internal
        returns (uint256, uint256)
    {
        ///@notice Initialize variables used throughout the function.
        uint128 protocolFee;
        uint128 beaconReward;
        uint128 conveyorReward;
        uint256 amountInWethToB;
        uint24 fee;

        ///@notice Check that the batch is not empty.
        if (!(batch.batchLength == 0)) {
            ///@notice If the tokenIn is not weth.
            if (batch.tokenIn != WETH) {
                ///@notice Get the UniV3 fee for the tokenA to Weth swap.
                fee = _getUniV3Fee(batch.lpAddressAToWeth);

                ///@notice Calculate the amountOutMin for tokenA to Weth.
                uint256 batchAmountOutMinAToWeth = ILimitOrderBatcher(LIMIT_ORDER_BATCHER).calculateAmountOutMinAToWeth(
                    batch.lpAddressAToWeth,
                    batch.amountIn,
                    0,
                    fee,
                    batch.tokenIn
                );

                ///@notice Swap from tokenA to Weth.
                uint128 amountOutWeth = uint128(
                    _swap(
                        batch.tokenIn,
                        WETH,
                        batch.lpAddressAToWeth,
                        fee,
                        batch.amountIn,
                        batchAmountOutMinAToWeth,
                        address(this),
                        address(this)
                    )
                );

                if (amountOutWeth == 0) {
                    revert InsufficientOutputAmount();
                }

                ///@notice Take out the fees from the amountOutWeth
                protocolFee = _calculateFee(amountOutWeth, USDC, WETH);

                ///@notice Calculate the conveyorReward and the off-chain logic executor reward.
                (conveyorReward, beaconReward) = _calculateReward(
                    protocolFee,
                    amountOutWeth
                );

                ///@notice Increment the conveyor balance by the conveyor reward.
                conveyorBalance += conveyorReward;

                ///@notice Get the amountIn for the Weth to tokenB swap.
                amountInWethToB =
                    amountOutWeth -
                    (beaconReward + conveyorReward);
            } else {
                ///@notice Otherwise, if the tokenIn is Weth

                ///@notice Take out fees from the batch amountIn since token0 is weth.
                protocolFee = _calculateFee(
                    uint128(batch.amountIn),
                    USDC,
                    WETH
                );

                ///@notice Calculate the conveyorReward and the off-chain logic executor reward.
                (conveyorReward, beaconReward) = _calculateReward(
                    protocolFee,
                    uint128(batch.amountIn)
                );

                ///@notice Increment the conveyor balance by the conveyor reward.
                conveyorBalance += conveyorReward;

                ///@notice Get the amountIn for the Weth to tokenB swap.
                amountInWethToB =
                    batch.amountIn -
                    (beaconReward + conveyorReward);
            }

            ///@notice Get the UniV3 fee for the Weth to tokenB swap.
            fee = _getUniV3Fee(batch.lpAddressWethToB);

            ///@notice Swap Weth for tokenB.
            uint256 amountOutInB = _swap(
                WETH,
                batch.tokenOut,
                batch.lpAddressWethToB,
                fee,
                amountInWethToB,
                batch.amountOutMin,
                address(this),
                address(this)
            );

            if (amountOutInB == 0) {
                revert InsufficientOutputAmount();
            }

            return (amountOutInB, uint256(beaconReward));
        } else {
            ///@notice If there are no orders in the batch, return 0 values for the amountOut (in tokenB) and the off-chain executor reward.
            return (0, 0);
        }
    }

    ///@notice Function to withdraw owner fee's accumulated
    function withdrawConveyorFees() external onlyOwner {
        safeTransferETH(owner, conveyorBalance);
        conveyorBalance = 0;
    }
}
