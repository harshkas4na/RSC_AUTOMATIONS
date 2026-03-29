// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../lib/reactive-lib/src/abstract-base/AbstractCallback.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "../lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/**
 * @title PersonalStopOrderCallback
 * @notice Personal stop order system for individual users
 * @dev Each user deploys their own instance for complete control and privacy
 */
contract PersonalStopOrderCallback is AbstractCallback {
    // Events
    event StopOrderCreated(
        address indexed pair,
        uint256 indexed orderId,
        bool sellToken0,
        address tokenSell,
        address tokenBuy,
        uint256 amount,
        uint256 coefficient,
        uint256 threshold
    );
    
    event StopOrderExecuted(
        address indexed pair,
        uint256 indexed orderId,
        address tokenSell,
        address tokenBuy,
        uint256 amountIn,
        uint256 amountOut
    );
    
    event StopOrderCancelled(uint256 indexed orderId);
    event StopOrderPaused(uint256 indexed orderId);
    event StopOrderResumed(uint256 indexed orderId);
    
    event ExecutionFailed(
        uint256 indexed orderId,
        string reason
    );
    
    // Order status enum
    enum OrderStatus { Active, Paused, Cancelled, Executed, Failed }
    
    // Stop order struct
    struct StopOrder {
        uint256 id;
        address pair;
        address tokenSell;
        address tokenBuy;
        uint256 amount;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderStatus status;
        uint256 createdAt;
        uint256 executedAt;
        uint8 retryCount;
        uint256 lastExecutionAttempt;
    }
    
    // State variables
    address public immutable owner;
    IUniswapV2Router02 public immutable router;
    
    mapping(uint256 => StopOrder) public stopOrders;
    uint256[] public orderIds; // Track all order IDs for easy enumeration
    uint256 public nextOrderId;
    
    // Configuration
    uint256 private constant DEADLINE_OFFSET = 300; // 5 minutes
    uint8 private constant MAX_RETRIES = 3;
    uint256 private constant RETRY_COOLDOWN = 30; // 30 seconds
    uint256 private constant MIN_AMOUNT = 1000; // Minimum amount to prevent dust
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }
    
    modifier validOrder(uint256 orderId) {
        require(orderId < nextOrderId, "Order does not exist");
        _;
    }
    
    constructor(
        address _owner,
        address _callbackSender,
        address _router
    ) AbstractCallback(_callbackSender) payable {
        owner = _owner;
        router = IUniswapV2Router02(_router);
    }
    
    /**
     * @notice Creates a new stop order
     * @param pair The Uniswap V2 pair address
     * @param sellToken0 Whether to sell token0 (true) or token1 (false)
     * @param amount Amount of tokens to sell
     * @param coefficient Price calculation coefficient
     * @param threshold Price threshold that triggers the order
     */
    function createStopOrder(
        address pair,
        bool sellToken0,
        uint256 amount,
        uint256 coefficient,
        uint256 threshold
    ) external onlyOwner returns (uint256) {
        require(pair != address(0), "Invalid pair address");
        require(amount >= MIN_AMOUNT, "Amount too small");
        require(coefficient > 0 && threshold > 0, "Invalid price parameters");
        
        // Get token addresses from pair
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        
        address tokenSell = sellToken0 ? token0 : token1;
        address tokenBuy = sellToken0 ? token1 : token0;
        
        // Verify user has sufficient balance
        require(IERC20(tokenSell).balanceOf(owner) >= amount, "Insufficient balance");
        
        // Verify user has approved sufficient amount
        require(
            IERC20(tokenSell).allowance(owner, address(this)) >= amount,
            "Insufficient allowance"
        );
        
        // Verify the pair is valid and has liquidity
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Pair has no liquidity");
        
        // Create the order
        uint256 orderId = nextOrderId;
        stopOrders[orderId] = StopOrder({
            id: orderId,
            pair: pair,
            tokenSell: tokenSell,
            tokenBuy: tokenBuy,
            amount: amount,
            sellToken0: sellToken0,
            coefficient: coefficient,
            threshold: threshold,
            status: OrderStatus.Active,
            createdAt: block.timestamp,
            executedAt: 0,
            retryCount: 0,
            lastExecutionAttempt: 0
        });
        
        // Add to order tracking
        orderIds.push(orderId);
        nextOrderId++;
        
        emit StopOrderCreated(
            pair,
            orderId,
            sellToken0,
            tokenSell,
            tokenBuy,
            amount,
            coefficient,
            threshold
        );
        
        return orderId;
    }
    
    /**
     * @notice Executes a stop order (called by RSC)
     * @dev Includes an on-chain price check as a final safeguard before execution
     * @param sender The address triggering the execution
     * @param orderId The ID of the order to execute
     */
    function executeStopOrder(
        address /*sender*/,
        uint256 orderId
    ) external authorizedSenderOnly validOrder(orderId) {
        StopOrder storage order = stopOrders[orderId];
        
        // Check order status
        if (order.status != OrderStatus.Active) {
            emit ExecutionFailed(orderId, "Order is not active");
            return;
        }

        // Final on-chain price check
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(order.pair).getReserves();
        require(
            _isBelowThreshold(order.sellToken0, reserve0, reserve1, order.coefficient, order.threshold),
            "Price condition not met"
        );
        
        // Check retry cooldown
        if (order.lastExecutionAttempt > 0 && 
            block.timestamp < order.lastExecutionAttempt + RETRY_COOLDOWN) {
            return;
        }
        
        // Check max retries
        if (order.retryCount >= MAX_RETRIES) {
            order.status = OrderStatus.Failed;
            emit ExecutionFailed(orderId, "Max retries exceeded");
            return;
        }
        
        // Update execution attempt
        order.lastExecutionAttempt = block.timestamp;
        order.retryCount++;
        
        // Check owner still has sufficient balance and allowance
        uint256 ownerBalance = IERC20(order.tokenSell).balanceOf(owner);
        uint256 ownerAllowance = IERC20(order.tokenSell).allowance(owner, address(this));
        
        uint256 executeAmount = order.amount;
        if (ownerBalance < executeAmount) {
            executeAmount = ownerBalance;
        }
        if (ownerAllowance < executeAmount) {
            executeAmount = ownerAllowance;
        }
        
        if (executeAmount < MIN_AMOUNT) {
            order.status = OrderStatus.Failed;
            emit ExecutionFailed(orderId, "Insufficient balance or allowance");
            return;
        }
        
        // Execute the swap
        (bool success, uint256 amountOut) = _executeSwap(order, executeAmount);
        
        if (success) {
            order.status = OrderStatus.Executed;
            order.executedAt = block.timestamp;
            
            emit StopOrderExecuted(
                order.pair,
                orderId,
                order.tokenSell,
                order.tokenBuy,
                executeAmount,
                amountOut
            );
        } else {
            emit ExecutionFailed(orderId, "Swap execution failed");
        }
    }
    
    /**
     * @notice Cancels a stop order
     * @param orderId The ID of the order to cancel
     */
    function cancelStopOrder(uint256 orderId) 
        external 
        onlyOwner
        validOrder(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(
            order.status == OrderStatus.Active || order.status == OrderStatus.Paused,
            "Cannot cancel order"
        );
        
        order.status = OrderStatus.Cancelled;
        emit StopOrderCancelled(orderId);
    }
    
    /**
     * @notice Pauses a stop order
     * @param orderId The ID of the order to pause
     */
    function pauseStopOrder(uint256 orderId) 
        external 
        onlyOwner
        validOrder(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Active, "Order is not active");
        
        order.status = OrderStatus.Paused;
        emit StopOrderPaused(orderId);
    }
    
    /**
     * @notice Resumes a paused stop order
     * @param orderId The ID of the order to resume
     */
    function resumeStopOrder(uint256 orderId) 
        external 
        onlyOwner
        validOrder(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Paused, "Order is not paused");
        
        order.status = OrderStatus.Active;
        emit StopOrderResumed(orderId);
    }
    
    /**
     * @notice Gets all order IDs
     * @return Array of all order IDs
     */
    function getAllOrders() external view returns (uint256[] memory) {
        return orderIds;
    }
    
    /**
     * @notice Gets active order IDs
     * @return Array of active order IDs
     */
    function getActiveOrders() external view returns (uint256[] memory) {
        uint256 activeCount = 0;
        
        // Count active orders
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (stopOrders[orderIds[i]].status == OrderStatus.Active) {
                activeCount++;
            }
        }
        
        // Build active orders array
        uint256[] memory activeOrders = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (stopOrders[orderIds[i]].status == OrderStatus.Active) {
                activeOrders[index] = orderIds[i];
                index++;
            }
        }
        
        return activeOrders;
    }
    
    /**
     * @notice Gets order details
     * @param orderId The order ID
     * @return The complete order struct
     */
    function getOrder(uint256 orderId) external view validOrder(orderId) returns (StopOrder memory) {
        return stopOrders[orderId];
    }
    
    /**
     * @notice Gets current price ratio for a pair (for informational purposes only)
     * @param pair The pair address
     * @param sellToken0 Whether selling token0
     * @return The current price ratio
     */
    function getCurrentPrice(address pair, bool sellToken0) external view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");
        
        if (sellToken0) {
            return (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            return (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }
    
    /**
     * @notice Internal function to execute the swap
     * @param order The order to execute
     * @param amount The amount to swap
     * @return success Whether the swap was successful
     * @return amountOut The amount of tokens received
     */
    function _executeSwap(StopOrder memory order, uint256 amount) internal returns (bool success, uint256 amountOut) {
        try this._performSwap(order.tokenSell, order.tokenBuy, amount) returns (uint256 _amountOut) {
            return (true, _amountOut);
        } catch {
            return (false, 0);
        }
    }
    
    /**
     * @notice External function for swap execution (used internally with try/catch)
     * @param tokenSell Token to sell
     * @param tokenBuy Token to buy
     * @param amount Amount to swap
     * @return amountOut Amount received
     */
    function _performSwap(
        address tokenSell,
        address tokenBuy,
        uint256 amount
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), "Internal function only");
        
        // Step 1: Transfer tokens from owner to contract
        require(IERC20(tokenSell).transferFrom(owner, address(this), amount), "Transfer failed");
        
        // Step 2: Approve router
        require(IERC20(tokenSell).approve(address(router), amount), "Approval failed");
        
        // Step 3: Execute swap to contract first
        address[] memory path = new address[](2);
        path[0] = tokenSell;
        path[1] = tokenBuy;
        
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + DEADLINE_OFFSET
        );
        
        // Step 4: Transfer received tokens to owner
        amountOut = amounts[1];
        require(IERC20(tokenBuy).transfer(owner, amountOut), "Final transfer failed");
        
        return amountOut;
    }
    
    /**
     * @notice Checks if the current on-chain price is below the order's threshold
     * @param sellToken0 True if selling token0, false if selling token1
     * @param reserve0 The reserve of token0 in the pair
     * @param reserve1 The reserve of token1 in the pair
     * @param coefficient The price coefficient from the order
     * @param threshold The price threshold from the order
     * @return True if the price condition is met, false otherwise
     */
    function _isBelowThreshold(
        bool sellToken0,
        uint112 reserve0,
        uint112 reserve1,
        uint256 coefficient,
        uint256 threshold
    ) internal pure returns (bool) {
        if (sellToken0) {
            // Price of token0 in terms of token1
            return (uint256(reserve1) * coefficient) / uint256(reserve0) <= threshold;
        } else {
            // Price of token1 in terms of token0
            return (uint256(reserve0) * coefficient) / uint256(reserve1) <= threshold;
        }
    }
    
    /**
     * @notice Emergency function to recover any stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover (0 for full balance)
     */
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 recoverAmount = amount == 0 ? balance : amount;
        require(recoverAmount <= balance, "Insufficient balance to recover");
        require(IERC20(token).transfer(owner, recoverAmount), "Recovery transfer failed");
    }

    // Emergency withdrawal functions - only deployer can call
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        require(amount <= address(this).balance, "Insufficient ETH balance");
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit ETHWithdrawn(to, amount);
    }


    function withdrawAllETH(address payable to) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH transfer failed");
        
        emit ETHWithdrawn(to, balance);
    }
}