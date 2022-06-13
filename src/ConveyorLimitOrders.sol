// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.13;

import "../lib/interfaces/token/IERC20.sol";
import "../lib/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import "../lib/interfaces/uniswap-v2/IUniswapV2Factory.sol";
import "../lib/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import "./test/utils/Console.sol";
import "../lib/interfaces/uniswap-v3/IUniswapV3Factory.sol";
import "../lib/interfaces/uniswap-v3/IUniswapV3Pool.sol";
import "../lib/libraries/ConveyorMath.sol";
import "./test/utils/Console.sol";
import "./OrderBook.sol";
import "./OrderRouter.sol";

///@notice for all order placement, order updates and order cancelation logic, see OrderBook
///@notice for all order fulfuillment logic, see OrderRouter

contract ConveyorLimitOrders is OrderBook, OrderRouter {
    //----------------------Modifiers------------------------------------//

    modifier onlyEOA() {
        require(msg.sender == tx.origin);
        _;
    }

    //----------------------Mappings------------------------------------//

    //mapping to hold users gas credit balances
    mapping(address => uint256) creditBalance;

    //----------------------State Variables------------------------------------//

    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    //----------------------Constructor------------------------------------//

    constructor(address _gasOracle) OrderBook(_gasOracle) {}

    //----------------------Events------------------------------------//
    event GasCreditEvent(
        bool indexed deposit,
        address indexed sender,
        uint256 amount
    );

    //----------------------Structs------------------------------------//

    /// @notice Struct containing the token, orderId, OrderType enum type, price, and quantity for each order
    //
    // struct Order {
    //     address tokenIn;
    //     address tokenOut;
    //     bytes32 orderId;
    //     OrderType orderType;
    //     uint256 price;
    //     uint256 quantity;
    // }

    // /// @notice enumeration of type of Order to be executed within the 'Order' Struct
    // enum OrderType {
    //     BUY,  -
    //     SELL, +
    //     STOP, -
    //     TAKE_PROFIT +
    // }
    //
    //

    struct TokenToTokenExecutionPrice {
        uint128 aToWethReserve0;
        uint128 aToWethReserve1;
        uint128 wethToBReserve0;
        uint128 wethToBReserve1;
        uint256 price;
        address lpAddressAToWeth;
        address lpAddressWethToB;
    }

    struct TokenToWethExecutionPrice {
        uint128 aToWethReserve0;
        uint128 aToWethReserve1;
        uint256 price;
        address lpAddressAToWeth;
    }

    struct TokenToWethBatchOrder {
        uint256 amountIn;
        uint256 amountOutMin;
        address tokenIn;
        address lpAddress;
        address[] batchOwners;
        uint256[] ownerShares;
        bytes32[] orderIds;
    }

    struct TokenToTokenBatchOrder {
        uint256 amountIn;
        //TODO: need to set amount out min somewhere
        uint256 amountOutMin;
        address tokenIn;
        address tokenOut;
        address lpAddressAToWeth;
        address lpAddressWethToB;
        address[] batchOwners;
        uint256[] ownerShares;
        bytes32[] orderIds;
    }

    //----------------------Functions------------------------------------//

    ///@notice This function takes in an array of orders,
    /// @param orders array of orders to be executed within the mapping
    function executeOrders(Order[] calldata orders) external onlyEOA {
        ///@notice validate that the order array is in ascending order by quantity
        _validateOrderSequencing(orders);

        ///@notice Sequence the orders by priority fee
        // Order[] memory sequencedOrders = _sequenceOrdersByPriorityFee(orders);

        ///@notice check if the token out is weth to determine what type of order execution to use
        if (orders[0].tokenOut == WETH) {
            _executeTokenToWethOrders(orders);
        } else {
            _executeTokenToTokenOrders(orders);
        }
    }

    ///@notice execute an array of orders from token to weth
    function _executeTokenToWethOrders(Order[] calldata orders) internal {
        ///@notice get all execution price possibilities
        TokenToWethExecutionPrice[]
            memory executionPrices = _initializeTokenToWethExecutionPrices(
                orders
            );

        ///@notice optimize the execution into batch orders, ensuring the best price for the least amount of gas possible
        TokenToWethBatchOrder[]
            memory tokenToWethBatchOrders = _batchTokenToWethOrders(
                orders,
                executionPrices
            );

        ///@notice execute the batch orders
        bool success = _executeTokenToWethBatchOrders(tokenToWethBatchOrders);
    }

    ///@notice execute an array of orders from token to token
    function _executeTokenToTokenOrders(Order[] calldata orders) internal {
        ///@notice get all execution price possibilities
        TokenToTokenExecutionPrice[]
            memory executionPrices = _initializeTokenToTokenExecutionPrices(
                orders
            );

        ///@notice optimize the execution into batch orders, ensuring the best price for the least amount of gas possible
        TokenToTokenBatchOrder[]
            memory tokenToTokenBatchOrders = _batchTokenToTokenOrders(
                orders,
                executionPrices
            );

        ///@notice execute the batch orders
        bool success = _executeTokenToTokenBatchOrders(tokenToTokenBatchOrders);
    }

    ///@notice initializes all routes from a to weth -> weth to b and returns an array of all combinations as ExectionPrice[]
    function _initializeTokenToWethExecutionPrices(Order[] calldata orders)
        internal
        view
        returns (TokenToWethExecutionPrice[] memory executionPrices)
    {
        (
            SpotReserve[] memory spotReserveAToWeth,
            address[] memory lpAddressesAToWeth
        ) = _getAllPrices(orders[0].tokenIn, WETH, 300, 1);

        {
            for (uint256 i = 0; i < spotReserveAToWeth.length; ++i) {
                executionPrices[i] = TokenToWethExecutionPrice(
                    spotReserveAToWeth[i].res0,
                    spotReserveAToWeth[i].res1,
                    0, //TODO: calculate initial price
                    lpAddressesAToWeth[i]
                );
            }
        }
    }

    ///@notice initializes all routes from a to weth -> weth to b and returns an array of all combinations as ExectionPrice[]
    function _initializeTokenToTokenExecutionPrices(Order[] calldata orders)
        internal
        view
        returns (TokenToTokenExecutionPrice[] memory executionPrices)
    {
        (
            SpotReserve[] memory spotReserveAToWeth,
            address[] memory lpAddressesAToWeth
        ) = _getAllPrices(orders[0].tokenIn, WETH, 300, 1);

        (
            SpotReserve[] memory spotReserveWethToB,
            address[] memory lpAddressWethToB
        ) = _getAllPrices(WETH, orders[0].tokenOut, 300, 1);

        {
            for (uint256 i = 0; i < spotReserveAToWeth.length; ++i) {
                for (uint256 j = 0; j < spotReserveWethToB.length; ++j) {
                    executionPrices[i] = TokenToTokenExecutionPrice(
                        spotReserveAToWeth[i].res0,
                        spotReserveAToWeth[i].res1,
                        spotReserveWethToB[j].res0,
                        spotReserveWethToB[j].res1,
                        0, //TODO: calculate initial price
                        lpAddressesAToWeth[i],
                        lpAddressWethToB[j]
                    );
                }
            }
        }
    }

    function _validateOrderSequencing(Order[] calldata orders) internal pure {
        for (uint256 j = 0; j < orders.length - 1; j++) {
            //TODO: change this to custom errors
            require(
                orders[j].quantity <= orders[j + 1].quantity,
                "Invalid Batch Ordering"
            );
        }
    }

    //TODO:
    function _sequenceOrdersByPriorityFee(Order[] calldata orders)
        internal
        returns (Order[] memory)
    {
        return orders;
    }

    function _buyOrSell(Order memory order) internal pure returns (bool) {
        //Determine high bool from batched OrderType
        if (
            order.orderType == OrderType.BUY ||
            order.orderType == OrderType.TAKE_PROFIT
        ) {
            return true;
        } else {
            return false;
        }
    }

    ///@notice agnostic swap function that determines whether or not to swap on univ2 or univ3
    function _swap(
        address tokenIn,
        address tokenOut,
        address lpAddress,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        if (_lpIsUniV2(lpAddress)) {
            amountOut = _swapV2(
                tokenIn,
                tokenOut,
                lpAddress,
                amountIn,
                amountOutMin
            );
        } else {
            amountOut = _swapV3(
                tokenIn,
                tokenOut,
                _getUniV3Fee(),
                lpAddress,
                amountIn,
                amountOutMin
            );
        }
    }

    //TODO:
    function _getUniV3Fee() internal returns (uint24 fee) {}

    ///@return (amountOut, beaconReward)
    ///@dev the amountOut is the amount out - protocol fees
    function _executeTokenToTokenBatch(TokenToTokenBatchOrder memory batch)
        internal
        returns (uint256, uint256)
    {
        ///@notice swap from A to weth
        uint128 amountOutWeth = uint128(
            _swap(
                batch.tokenIn,
                WETH,
                batch.lpAddressAToWeth,
                batch.amountIn,
                batch.amountOutMin
            )
        );

        ///@notice take out fees
        uint128 protocolFee = _calculateFee(amountOutWeth);
        (uint128 conveyorReward, uint128 beaconReward) = _calculateReward(
            protocolFee,
            amountOutWeth
        );

        ///@notice get amount in for weth to B
        uint256 amountInWethToB = amountOutWeth - protocolFee;

        ///@notice swap weth for B
        uint256 amountOutInB = _swap(
            WETH,
            batch.tokenOut,
            batch.lpAddressWethToB,
            amountInWethToB,
            //TODO: determine how much for amount out min
            batch.amountOutMin
        );

        return (amountOutInB, uint256(beaconReward));
    }

    function _lpIsUniV2(address lp) internal returns (bool) {}

    function _executeTokenToWethBatchOrders(
        TokenToWethBatchOrder[] memory tokenToWethBatchOrders
    ) private returns (bool) {
        uint256 totalBeaconReward;

        for (uint256 i = 0; i < tokenToWethBatchOrders.length; i++) {
            ///@notice _execute order
            //TODO: return the (amountOut, protocolRevenue)
            (
                uint256 amountOut,
                uint256 beaconReward
            ) = _executeTokenToWethBatch(tokenToWethBatchOrders[i]);

            ///@notice add the beacon reward to the totalBeaconReward
            totalBeaconReward += beaconReward;

            ///@notice calculate how much to pay each user from the shares they own

            ///@notice for each user, pay out in a loop
        }

        ///@notice calculate the beacon runner profit and pay the beacon
    }

    function _executeTokenToWethBatch(TokenToWethBatchOrder memory batch)
        internal
        returns (uint256, uint256)
    {
        ///@notice swap from A to weth
        uint128 amountOutWeth = uint128(
            _swap(
                batch.tokenIn,
                WETH,
                batch.lpAddress,
                batch.amountIn,
                batch.amountOutMin
            )
        );

        ///@notice take out fees
        uint128 protocolFee = _calculateFee(amountOutWeth);
        (uint128 conveyorReward, uint128 beaconReward) = _calculateReward(
            protocolFee,
            amountOutWeth
        );

        return (uint256(amountOutWeth - protocolFee), uint256(beaconReward));
    }

    function _executeTokenToTokenBatchOrders(
        TokenToTokenBatchOrder[] memory tokenToTokenBatchOrders
    ) private returns (bool) {
        uint256 totalBeaconReward;

        for (uint256 i = 0; i < tokenToTokenBatchOrders.length; i++) {
            ///@notice _execute order
            //TODO: return the (amountOut, protocolRevenue)
            (
                uint256 amountOut,
                uint256 beaconReward
            ) = _executeTokenToTokenBatch(tokenToTokenBatchOrders[i]);

            ///@notice add the beacon reward to the totalBeaconReward
            totalBeaconReward += beaconReward;

            ///@notice calculate how much to pay each user from the shares they own

            ///@notice for each user, pay out in a loop
        }

        ///@notice calculate the beacon runner profit and pay the beacon
    }

    function _calculateTokenToTokenPrice(
        Order[] memory orders,
        uint128 aToWethReserve0,
        uint128 aToWethReserve1,
        uint128 wethToBReserve0,
        uint128 wethToBReserve1
    ) internal returns (uint256 spotPrice) {}

    function _calculateTokenToWethPrice(
        Order[] memory orders,
        uint128 aToWethReserve0,
        uint128 aToWethReserve1
    ) internal returns (uint256 spotPrice) {}

    function _batchTokenToWethOrders(
        Order[] memory orders,
        TokenToWethExecutionPrice[] memory executionPrices
    ) internal returns (TokenToWethBatchOrder[] memory) {}

    function _batchTokenToTokenOrders(
        Order[] memory orders,
        TokenToTokenExecutionPrice[] memory executionPrices
    )
        internal
        returns (TokenToTokenBatchOrder[] memory tokenToTokenBatchOrders)
    {
        Order memory firstOrder = orders[0];
        bool buyOrder = _buyOrSell(firstOrder);

        address batchOrderTokenIn = firstOrder.tokenIn;
        address batchOrderTokenOut = firstOrder.tokenOut;

        uint256 currentBestPriceIndex = _findBestTokenToTokenExecutionPrice(
            executionPrices,
            buyOrder
        );

        TokenToTokenBatchOrder
            memory currentTokenToTokenBatchOrder = _initializeNewTokenToTokenBatchOrder(
                orders.length,
                batchOrderTokenIn,
                batchOrderTokenOut,
                executionPrices[currentBestPriceIndex].lpAddressAToWeth,
                executionPrices[currentBestPriceIndex].lpAddressWethToB
            );

        //loop each order
        for (uint256 i = 0; i < orders.length; i++) {
            //TODO: this is repetitive, we can do the first iteration and then start from n=1
            ///@notice get the index of the best exectuion price
            uint256 bestPriceIndex = _findBestTokenToTokenExecutionPrice(
                executionPrices,
                buyOrder
            );

            ///@notice if the best price has changed since the last order
            if (i > 0 && currentBestPriceIndex != bestPriceIndex) {
                ///@notice add the current batch order to the batch orders array
                tokenToTokenBatchOrders[
                    tokenToTokenBatchOrders.length
                ] = currentTokenToTokenBatchOrder;

                //-
                ///@notice update the currentBestPriceIndex
                currentBestPriceIndex = bestPriceIndex;

                ///@notice add the batch order to tokenToTokenBatchOrders
                tokenToTokenBatchOrders[
                    tokenToTokenBatchOrders.length
                ] = currentTokenToTokenBatchOrder;

                ///@notice initialize a new batch order
                //TODO: need to implement logic to trim 0 val orders
                currentTokenToTokenBatchOrder = _initializeNewTokenToTokenBatchOrder(
                    orders.length,
                    batchOrderTokenIn,
                    batchOrderTokenOut,
                    executionPrices[bestPriceIndex].lpAddressAToWeth,
                    executionPrices[bestPriceIndex].lpAddressWethToB
                );
            }

            ///@notice get the best execution price
            uint256 executionPrice = executionPrices[bestPriceIndex].price;

            Order memory currentOrder = orders[i];

            ///@notice if the order meets the execution price
            if (
                _orderMeetsExecutionPrice(
                    currentOrder.price,
                    executionPrice,
                    buyOrder
                )
            ) {
                ///@notice if the order can execute without hitting slippage
                if (_orderCanExecute()) {
                    uint256 batchOrderLength = currentTokenToTokenBatchOrder
                        .batchOwners
                        .length;

                    ///@notice add the order to the current batch order
                    //TODO: can reduce size by just adding ownerShares on execution
                    currentTokenToTokenBatchOrder.amountIn += currentOrder
                        .quantity;

                    ///@notice add owner of the order to the batchOwners
                    currentTokenToTokenBatchOrder.batchOwners[
                        batchOrderLength
                    ] = currentOrder.owner;

                    ///@notice add the order quantity of the order to ownerShares
                    currentTokenToTokenBatchOrder.ownerShares[
                        batchOrderLength
                    ] = currentOrder.quantity;

                    ///@notice add the orderId to the batch order
                    currentTokenToTokenBatchOrder.orderIds[
                        batchOrderLength
                    ] = currentOrder.orderId;

                    ///TODO: update execution price at the previous index
                } else {
                    //TODO:
                    ///@notice cancel the order due to insufficient slippage
                }
            }
        }
    }

    function _initializeNewTokenToTokenBatchOrder(
        uint256 initArrayLength,
        address tokenIn,
        address tokenOut,
        address lpAddressAToWeth,
        address lpAddressWethToB
    ) internal pure returns (TokenToTokenBatchOrder memory) {
        ///@notice initialize a new batch order
        return
            TokenToTokenBatchOrder(
                ///@notice initialize amountIn
                0,
                ///@notice initialize amountOutMin
                0,
                ///@notice add the token in
                tokenIn,
                ///@notice add the token out
                tokenOut,
                ///@notice initialize A to weth lp
                lpAddressAToWeth,
                ///@notice initialize weth to B lp
                lpAddressWethToB,
                ///@notice initialize batchOwners
                new address[](initArrayLength),
                ///@notice initialize ownerShares
                new uint256[](initArrayLength),
                ///@notice initialize orderIds
                new bytes32[](initArrayLength)
            );
    }

    ///@notice returns the index of the best price in the executionPrices array
    ///@param buyOrder indicates if the batch is a buy or a sell
    function _findBestTokenToTokenExecutionPrice(
        TokenToTokenExecutionPrice[] memory executionPrices,
        bool buyOrder
    ) internal pure returns (uint256 bestPriceIndex) {
        ///@notice if the order is a buy order, set the initial best price at 0, else set the initial best price at max uint256
        uint256 bestPrice = buyOrder
            ? 0
            : 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        for (uint256 i = 0; i < executionPrices.length; i++) {
            uint256 executionPrice = executionPrices[i].price;
            if (executionPrice > bestPrice) {
                bestPrice = executionPrice;
                bestPriceIndex = i;
            }
        }
    }

    ///@notice returns the index of the best price in the executionPrices array

    function _findBestTokenToWethExecutionPrice(
        TokenToWethExecutionPrice[] memory executionPrices,
        bool buyOrder
    ) internal pure returns (uint256 bestPriceIndex) {
        ///@notice if the order is a buy order, set the initial best price at 0, else set the initial best price at max uint256
        uint256 bestPrice = buyOrder
            ? 0
            : 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        for (uint256 i = 0; i < executionPrices.length; i++) {
            uint256 executionPrice = executionPrices[i].price;
            if (executionPrice > bestPrice) {
                bestPrice = executionPrice;
                bestPriceIndex = i;
            }
        }
    }

    /// @notice Helper function to determine the spot price change to the lp after introduction alphaX amount into the reserve pool
    /// @param alphaX uint256 amount to be added to reserve_x to get out token_y
    /// @param reserves current lp reserves for tokenIn and tokenOut
    /// @return unsigned The amount of proportional spot price change in the pool after adding alphaX to the tokenIn reserves
    function simulatePriceChange(uint128 alphaX, uint128[] memory reserves)
        internal
        pure
        returns (uint256, uint128[] memory)
    {
        uint128[] memory newReserves = new uint128[](2);

        unchecked {
            uint128 numerator = reserves[0] + alphaX;
            uint256 k = uint256(reserves[0] * reserves[1]);

            uint128 denominator = ConveyorMath.divUI(
                k,
                uint256(reserves[0] + alphaX)
            );

            uint256 spotPrice = uint256(
                ConveyorMath.div128x128(
                    uint256(numerator) << 128,
                    uint256(denominator) << 64
                )
            );

            require(
                spotPrice <=
                    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
                "overflow"
            );
            newReserves[0] = numerator;
            newReserves[1] = denominator;
            return (uint256(spotPrice), newReserves);
        }
    }

    /// @notice Helper function to determine if order can execute based on the spot price of the lp, the determinig factor is the order.orderType

    function _orderMeetsExecutionPrice(
        uint256 orderPrice,
        uint256 executionPrice,
        bool buyOrder
    ) internal pure returns (bool) {
        if (buyOrder) {
            return executionPrice <= orderPrice;
        } else {
            return executionPrice >= orderPrice;
        }
    }

    ///@notice checks if order can complete without hitting slippage
    //TODO:
    function _orderCanExecute() internal pure returns (bool) {}

    /// @notice deposit gas credits publicly callable function
    /// @return bool boolean indicator whether deposit was successfully transferred into user's gas credit balance
    function depositCredits() public payable returns (bool) {
        //Require that deposit amount is strictly == ethAmount maybe keep this
        // require(msg.value == ethAmount, "Deposit amount misnatch");

        //Check if sender balance can cover eth deposit
        // Todo write this in assembly
        if (address(msg.sender).balance < msg.value) {
            return false;
        }

        //Add amount deposited to creditBalance of the user
        creditBalance[msg.sender] += msg.value;

        //Emit credit deposit event for beacon
        emit GasCreditEvent(true, msg.sender, msg.value);

        //return bool success
        return true;
    }
}
