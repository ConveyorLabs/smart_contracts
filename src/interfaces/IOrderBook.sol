// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../OrderBook.sol";

interface IOrderBook {
    ///@notice This function gets an order by the orderId. If the order does not exist, the order returned will be empty.
    function getOrderById(bytes32 orderId)
        external
        view
        returns (OrderBook.Order memory order);

    function placeOrder(OrderBook.Order[] calldata orderGroup)
        external
        returns (bytes32[] memory);

    function updateOrder(OrderBook.Order memory newOrder) external;

    function cancelOrder(bytes32 orderId) external;

    function cancelOrders(bytes32[] memory orderIds) external;

    function getAllOrderIds(address owner)
        external
        view
        returns (bytes32[][] memory);
    function getGasPrice() external view returns (uint256); 
}
