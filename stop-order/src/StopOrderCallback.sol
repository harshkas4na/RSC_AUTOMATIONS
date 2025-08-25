// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../lib/reactive-lib/src/abstract-base/AbstractCallback.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "../lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract StopOrderCallback is AbstractCallback {
    // Events
    event StopOrderCreated(
        address indexed pair,
        uint256 indexed orderId,
        address indexed client,
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
        address indexed client,
        address tokenSell,
        address tokenBuy,
        uint256 amountIn,
        uint256 amountOut
    );
    
    event StopOrderCancelled(
        uint256 indexed orderId,
        address indexed client
    );
    
    event StopOrderPaused(
        uint256 indexed orderId,
        address indexed client
    );
    
    event StopOrderResumed(
        uint256 indexed orderId,
        address indexed client
    );
    
    event ExecutionFailed(
        uint256 indexed orderId,
        string reason
    );
    
    // Order status enum
    enum OrderStatus { Active, Paused, Cancelled, Executed, Failed }
    
    // Stop order struct
    struct StopOrder {
        uint256 id;
        address client;
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
    IUniswapV2Router02 public immutable router;
    
    mapping(uint256 => StopOrder) public stopOrders;
    mapping(address => uint256[]) public userOrders;
    uint256 public nextOrderId;
    
    // Configuration
    uint256 private constant DEADLINE_OFFSET = 300; // 5 minutes
    uint8 private constant MAX_RETRIES = 3;
    uint256 private constant RETRY_COOLDOWN = 30; // 30 sec
    uint256 private constant MIN_AMOUNT = 1000; // Minimum amount to prevent dust
    
    // Modifiers
    modifier onlyOrderOwner(uint256 orderId) {
        require(stopOrders[orderId].client == msg.sender, "Not order owner");
        _;
    }
    
    modifier validOrder(uint256 orderId) {
        require(orderId < nextOrderId, "Order does not exist");
        _;
    }
    
    constructor(
        address _callbackSender,
        address _router
    ) AbstractCallback(_callbackSender) payable {
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
    function createStopOrder (
        address pair,
        bool sellToken0,
        uint256 amount,
        uint256 coefficient,
        uint256 threshold
    ) external payable returns (uint256) {
        require(pair != address(0), "Invalid pair address");
        require(amount >= MIN_AMOUNT, "Amount too small");
        require(coefficient > 0 && threshold > 0, "Invalid price parameters");
        
        // Get token addresses from pair
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        
        address tokenSell = sellToken0 ? token0 : token1;
        address tokenBuy = sellToken0 ? token1 : token0;
        
        // Verify user has sufficient balance
        require(IERC20(tokenSell).balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Verify user has approved sufficient amount
        require(
            IERC20(tokenSell).allowance(msg.sender, address(this)) >= amount,
            "Insufficient allowance"
        );
        
        // Verify the pair is valid and has liquidity
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Pair has no liquidity");
        
        // Create the order
        uint256 orderId = nextOrderId;
        stopOrders[orderId] = StopOrder({
            id: orderId,
            client: msg.sender,
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
        
        // Add to user's orders
        userOrders[msg.sender].push(orderId);
        
        nextOrderId++;
        
        emit StopOrderCreated(
            pair,
            orderId,
            msg.sender,
            sellToken0,
            tokenSell,
            tokenBuy,
            amount,
            coefficient,
            threshold
        );
        
        return orderId;
    }
    
    /*
     * @notice Executes a stop order (called by RSC)
     * @dev Includes an on-chain price check as a final safeguard before execution.
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

        // While the RSC triggers this call, we perform a final on-chain check
        // to ensure the price condition is met at the moment of execution.
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(order.pair).getReserves();
        require(
            _isBelowThreshold(order.sellToken0, reserve0, reserve1, order.coefficient, order.threshold),
            "Price condition not met"
        );
        
        // Check retry cooldown
        if (order.lastExecutionAttempt > 0 && 
            block.timestamp < order.lastExecutionAttempt + RETRY_COOLDOWN) {
            return; // Skip execution if in cooldown
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
        
        // Check user still has sufficient balance and allowance
        uint256 userBalance = IERC20(order.tokenSell).balanceOf(order.client);
        uint256 userAllowance = IERC20(order.tokenSell).allowance(order.client, address(this));
        
        uint256 executeAmount = order.amount;
        if (userBalance < executeAmount) {
            executeAmount = userBalance;
        }
        if (userAllowance < executeAmount) {
            executeAmount = userAllowance;
        }
        
        if (executeAmount < MIN_AMOUNT) {
            order.status = OrderStatus.Failed;
            emit ExecutionFailed(orderId, "Insufficient balance or allowance");
            return;
        }
        
        // Execute the swap
        bool success = _executeSwap(order, executeAmount);
        
        if (success) {
            order.status = OrderStatus.Executed;
            order.executedAt = block.timestamp;
            
            emit StopOrderExecuted(
                order.pair,
                orderId,
                order.client,
                order.tokenSell,
                order.tokenBuy,
                executeAmount,
                0 // amountOut will be in the Swap event from Uniswap
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
        validOrder(orderId) 
        onlyOrderOwner(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(
            order.status == OrderStatus.Active || order.status == OrderStatus.Paused,
            "Cannot cancel order"
        );
        
        order.status = OrderStatus.Cancelled;
        
        emit StopOrderCancelled(orderId, msg.sender);
    }
    
    /**
     * @notice Pauses a stop order
     * @param orderId The ID of the order to pause
     */
    function pauseStopOrder(uint256 orderId) 
        external 
        validOrder(orderId) 
        onlyOrderOwner(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Active, "Order is not active");
        
        order.status = OrderStatus.Paused;
        
        emit StopOrderPaused(orderId, msg.sender);
    }
    
    /**
     * @notice Resumes a paused stop order
     * @param orderId The ID of the order to resume
     */
    function resumeStopOrder(uint256 orderId) 
        external 
        validOrder(orderId) 
        onlyOrderOwner(orderId) 
    {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Paused, "Order is not paused");
        
        order.status = OrderStatus.Active;
        
        emit StopOrderResumed(orderId, msg.sender);
    }
    
    /**
     * @notice Gets user's orders
     * @param user The user address
     * @return Array of order IDs
     */
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
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
    
    
    function _executeSwap(StopOrder memory order, uint256 amount) internal returns (bool) {
        address tokenSell = order.tokenSell;
        address tokenBuy = order.tokenBuy;
        address client = order.client;
        
        // Validate first
        uint256 clientBalance = IERC20(tokenSell).balanceOf(client);
        if (clientBalance < amount) return false;
        
        uint256 allowance = IERC20(tokenSell).allowance(client, address(this));
        if (allowance < amount) return false;
        
        // Step 1: Transfer tokens from client to contract
        require(IERC20(tokenSell).transferFrom(client, address(this), amount), "Transfer failed");
        
        // Step 2: Approve router
        require(IERC20(tokenSell).approve(address(router), amount), "Approval failed");
        
        // Step 3: Execute swap TO CONTRACT FIRST
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
        
        // Step 4: Transfer received tokens to client
        uint256 amountOut = amounts[1];
        require(IERC20(tokenBuy).transfer(client, amountOut), "Final transfer failed");
        
        return true;
    }
    
    /**
     * @notice Checks if the current on-chain price is below the order's threshold.
     * @param sellToken0 True if selling token0, false if selling token1.
     * @param reserve0 The reserve of token0 in the pair.
     * @param reserve1 The reserve of token1 in the pair.
     * @param coefficient The price coefficient from the order.
     * @param threshold The price threshold from the order.
     * @return True if the price condition is met, false otherwise.
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
    
}