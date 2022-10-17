// SPDX-License-Identifier: MIT
pragma solidity >=0.8.16;

error InsufficientGasCreditBalance();
error InsufficientGasCreditBalanceForOrderExecution();
error InsufficientWalletBalance();
error OrderDoesNotExist(bytes32 orderId);
error OrderHasInsufficientSlippage(bytes32 orderId);
error SwapFailed(bytes32 orderId);
error OrderDoesNotMeetExecutionPrice(bytes32 orderId);
error TokenTransferFailed(bytes32 orderId);
error IncongruentTokenInOrderGroup();
error OrderNotRefreshable();
error OrderHasReachedExpiration();
error InsufficientOutputAmount();
error InsufficientInputAmount();
error InsufficientLiquidity();
error MsgSenderIsNotOwner();
error InsufficientDepositAmount();
error InsufficientAllowanceForOrderPlacement();
error InvalidBatchOrder();
error IncongruentInputTokenInBatch();
error IncongruentOutputTokenInBatch();
error IncongruentTaxedTokenInBatch();
error IncongruentBuySellStatusInBatch();
error WethWithdrawUnsuccessful();
error MsgSenderIsNotTxOrigin();
error Reentrancy();
error ETHTransferFailed();
error InvalidTokenPairIdenticalAddress();
error InvalidTokenPair();
error InvalidAddress();
error UnauthorizedCaller();
error UnauthorizedUniswapV3CallbackCaller();
error InvalidOrderUpdate();

