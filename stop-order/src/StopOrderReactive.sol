// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../lib/reactive-lib/src/interfaces/IReactive.sol";
import "../lib/reactive-lib/src/abstract-base/AbstractReactive.sol";

contract StopOrderReactive is IReactive, AbstractReactive {
    // Events
    event OrderTracked(
        address indexed pair,
        uint256 indexed orderId,
        address indexed client
    );
    
    event OrderUntracked(
        address indexed pair,
        uint256 indexed orderId
    );
    
    event PairSubscribed(
        address indexed pair
    );
    
    event PairUnsubscribed(
        address indexed pair
    );
    
    event ExecutionTriggered(
        uint256 indexed orderId,
        address indexed pair,
        bool priceConditionMet
    );
    
    event ProcessingError(
        string reason,
        uint256 orderId
    );
    
    // Added debug event to see exact threshold calculations
    event ThresholdCheck(
        uint256 indexed orderId,
        uint256 calculated,
        uint256 threshold,
        bool conditionMet,
        bool sellToken0
    );
    
    // Constants
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 private constant REACTIVE_CHAIN_ID = 5318007; // Lasna network chain ID
    uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 private constant STOP_ORDER_CREATED_TOPIC_0 = 0x9b04d9cf86fd3b602bd071c32af665e7d3937a1e5b1b9cf1dd38a8343b595b2a; // keccak256("StopOrderCreated(address,uint256,address,bool,address,address,uint256,uint256,uint256)")
    uint256 private constant STOP_ORDER_CANCELLED_TOPIC_0 = 0xfe37e6bb58b8cd2f910ea053f64bb539b39cc1c88a576a320b59bcbf4f339dfc; // keccak256("StopOrderCancelled(uint256,address)")
    uint256 private constant STOP_ORDER_EXECUTED_TOPIC_0 = 0x2a5962540e657deb5eb7f9238cc31815325d1e74cf8e6415ea3d7a5b9886997d; // keccak256("StopOrderExecuted(address,uint256,address,address,address,uint256,uint256)")
    uint256 private constant STOP_ORDER_PAUSED_TOPIC_0 = 0x552b2dd798eedf0c450199b5a7c35ff9f2955c113876b1afbe87060335b31653; // keccak256("StopOrderPaused(uint256,address)")
    uint256 private constant STOP_ORDER_RESUMED_TOPIC_0 = 0x9bffe4738606691ddfa5e5d28208b6ef74537676b39ddb9854b7854a62df0692; // keccak256("StopOrderResumed(uint256,address)")
    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;
    
    // Order status enum (mirrors the callback contract)
    enum OrderStatus { Active, Paused, Cancelled, Executed, Failed }
    
    // Reserves struct for Uniswap sync events
    struct Reserves {
        uint112 reserve0;
        uint112 reserve1;
    }
    
    // Order tracking struct
    struct TrackedOrder {
        uint256 id;
        address pair;
        address client;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderStatus status;
        uint256 lastTriggeredAt;
        uint8 triggerCount;
    }
    
    // State variables
    address private stopOrderCallback;
    
    // Order tracking
    mapping(uint256 => TrackedOrder) private trackedOrders;
    mapping(address => uint256[]) private pairOrders; // pair -> orderIds
    mapping(address => uint256) private pairOrderCount;
    mapping(address => bool) private subscribedPairs;
    
    // Constants for retry logic
    uint256 private constant TRIGGER_COOLDOWN = 300; // 5 minutes between triggers
    uint8 private constant MAX_TRIGGER_ATTEMPTS = 5;
    
    constructor(address _stopOrderCallback) payable {
        stopOrderCallback = _stopOrderCallback;
        
        if (!vm) {
            // Subscribe to stop order lifecycle events
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stopOrderCallback,
                STOP_ORDER_CREATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stopOrderCallback,
                STOP_ORDER_CANCELLED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stopOrderCallback,
                STOP_ORDER_EXECUTED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stopOrderCallback,
                STOP_ORDER_PAUSED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stopOrderCallback,
                STOP_ORDER_RESUMED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }
    
    // Main reaction function
    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == stopOrderCallback) {
            _processStopOrderEvent(log);
        } else if (log.topic_0 == UNISWAP_V2_SYNC_TOPIC_0 && subscribedPairs[log._contract]) {
            _processSyncEvent(log);
        }
    }
    
    // Process stop order lifecycle events
    function _processStopOrderEvent(LogRecord calldata log) internal {
        if (log.topic_0 == STOP_ORDER_CREATED_TOPIC_0) {
            _processOrderCreated(log);
        } else if (log.topic_0 == STOP_ORDER_CANCELLED_TOPIC_0) {
            _processOrderCancelled(log);
        } else if (log.topic_0 == STOP_ORDER_EXECUTED_TOPIC_0) {
            _processOrderExecuted(log);
        } else if (log.topic_0 == STOP_ORDER_PAUSED_TOPIC_0) {
            _processOrderPaused(log);
        } else if (log.topic_0 == STOP_ORDER_RESUMED_TOPIC_0) {
            _processOrderResumed(log);
        }
    }
    
    // Process order creation
    function _processOrderCreated(LogRecord calldata log) internal {
        // Extract data from event topics
        address pair = address(uint160(log.topic_1));
        uint256 orderId = uint256(log.topic_2);
        address client = address(uint160(log.topic_3));
        
        // Decode additional data from log.data
        (
            bool sellToken0,
            address tokenSell,
            address tokenBuy,
            uint256 amount,
            uint256 coefficient,
            uint256 threshold
        ) = abi.decode(log.data, (bool, address, address, uint256, uint256, uint256));
        
        // Track the order
        trackedOrders[orderId] = TrackedOrder({
            id: orderId,
            pair: pair,
            client: client,
            sellToken0: sellToken0,
            coefficient: coefficient,
            threshold: threshold,
            status: OrderStatus.Active,
            lastTriggeredAt: 0,
            triggerCount: 0
        });
        
        // Add to pair's order list
        pairOrders[pair].push(orderId);
        
        // Subscribe to pair if this is the first order - USING CALLBACK MECHANISM
        if (pairOrderCount[pair] == 0) {
            _requestPairSubscription(pair, log.chain_id);
        }
        
        pairOrderCount[pair]++;
        
        emit OrderTracked(pair, orderId, client);
    }
    
    // Process order cancellation
    function _processOrderCancelled(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        address client = address(uint160(log.topic_2));
        
        if (trackedOrders[orderId].id == orderId) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Cancelled;
            
            _decrementPairCount(pair);
            
            emit OrderUntracked(pair, orderId);
        }
    }
    
    // Process order execution
    function _processOrderExecuted(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_2);
        
        if (trackedOrders[orderId].id == orderId) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Executed;
            
            _decrementPairCount(pair);
            
            emit OrderUntracked(pair, orderId);
        }
    }
    
    // Process order pause
    function _processOrderPaused(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        
        if (trackedOrders[orderId].id == orderId) {
            trackedOrders[orderId].status = OrderStatus.Paused;
        }
    }
    
    // Process order resume
    function _processOrderResumed(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        
        if (trackedOrders[orderId].id == orderId) {
            trackedOrders[orderId].status = OrderStatus.Active;
        }
    }
    
    // Process Uniswap sync events - THE CORE LOGIC
    function _processSyncEvent(LogRecord calldata log) internal {
        address pair = log._contract;
        Reserves memory reserves = abi.decode(log.data, (Reserves));
        
        // Get all orders for this pair
        uint256[] storage orderIds = pairOrders[pair];
        
        for (uint i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            TrackedOrder storage order = trackedOrders[orderId];
            
            // Skip non-active orders
            if (order.status != OrderStatus.Active) {
                continue;
            }
            
            // Check trigger cooldown
            if (order.lastTriggeredAt > 0 && 
                block.timestamp < order.lastTriggeredAt + TRIGGER_COOLDOWN) {
                continue;
            }
            
            // Check max trigger attempts
            if (order.triggerCount >= MAX_TRIGGER_ATTEMPTS) {
                order.status = OrderStatus.Failed;
                emit ProcessingError("Max retries exceeded", orderId);
                continue;
            }
            
            // Check if price condition is met - THIS IS THE ONLY PLACE!
            bool shouldTrigger = _isPriceConditionMet(
                order.sellToken0,
                reserves,
                order.coefficient,
                order.threshold
            );
            
            // Emit detailed debug event
            uint256 calculated;
            if (order.sellToken0) {
                calculated = (uint256(reserves.reserve1) * order.coefficient) / uint256(reserves.reserve0);
            } else {
                calculated = (uint256(reserves.reserve0) * order.coefficient) / uint256(reserves.reserve1);
            }
            
            emit ThresholdCheck(orderId, calculated, order.threshold, shouldTrigger, order.sellToken0);
            
            if (shouldTrigger) {
                _triggerExecution(orderId, pair);
            }
        }
    }
    
    // Check if price condition is met - THE AUTHORITATIVE CHECK
    function _isPriceConditionMet(
        bool sellToken0,
        Reserves memory reserves,
        uint256 coefficient,
        uint256 threshold
    ) internal pure returns (bool) {
        if (sellToken0) {
            return (uint256(reserves.reserve1) * coefficient) / uint256(reserves.reserve0) <= threshold;
        } else {
            return (uint256(reserves.reserve0) * coefficient) / uint256(reserves.reserve1) <= threshold;
        }
    }
    
    // Trigger order execution
    function _triggerExecution(uint256 orderId, address pair) internal {
        TrackedOrder storage order = trackedOrders[orderId];
        
        // Update trigger tracking
        order.lastTriggeredAt = block.timestamp;
        order.triggerCount++;
        
        // Create callback payload
        bytes memory payload = abi.encodeWithSignature(
            "executeStopOrder(address,uint256)",
            address(0), // sender is ignored in callback
            orderId
        );
        
        // Emit callback to Sepolia chain
        emit Callback(SEPOLIA_CHAIN_ID, stopOrderCallback, CALLBACK_GAS_LIMIT, payload);
        
        emit ExecutionTriggered(orderId, pair, true);
    }
    
    // DYNAMIC SUBSCRIPTION MANAGEMENT USING CALLBACK MECHANISM
    
    // Request pair subscription using callback mechanism
    function _requestPairSubscription(address pair, uint256 chainId) internal {
        if (!subscribedPairs[pair]) {
            // Create a callback to subscribe on the Reactive Network
            bytes memory payload = abi.encodeWithSignature(
                "subscribeToPair(address,address,uint256)",
                address(0),
                pair,
                chainId
            );
            
            // Emit callback to Reactive Network to handle the subscription
            emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload);
            
            // Mark as requested (will be confirmed when subscription is active)
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
        }
    }
    
    // Request pair unsubscription using callback mechanism
    function _requestPairUnsubscription(address pair, uint256 chainId) internal {
        if (subscribedPairs[pair]) {
            // Create a callback to unsubscribe on the Reactive Network
            bytes memory payload = abi.encodeWithSignature(
                "unsubscribeFromPair(address,address,uint256)",
                address(0),
                pair,
                chainId
            );
            
            // Emit callback to Reactive Network to handle the unsubscription
            emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload);
            
            // Mark as requested (will be confirmed when unsubscription is processed)
            subscribedPairs[pair] = false;
            emit PairUnsubscribed(pair);
        }
    }
    
    // Methods for Reactive Network to execute subscription (via callback)
    function subscribeToPair(address /*sender*/, address pair, uint256 chainId) external rnOnly {
        // Execute the subscription
        service.subscribe(
            chainId,
            pair,
            UNISWAP_V2_SYNC_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
    
    // Methods for Reactive Network to execute unsubscription (via callback)
    function unsubscribeFromPair(address /*sender*/, address pair, uint256 chainId) external rnOnly {
        // Execute the unsubscription
        service.unsubscribe(
            chainId,
            pair,
            UNISWAP_V2_SYNC_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
    
    // Decrement pair order count and unsubscribe if needed
    function _decrementPairCount(address pair) internal {
        if (pairOrderCount[pair] > 0) {
            pairOrderCount[pair]--;
            
            // Unsubscribe if no more active orders
            if (pairOrderCount[pair] == 0) {
                _requestPairUnsubscription(pair, SEPOLIA_CHAIN_ID);
            }
        }
    }
    
    // View functions
    function getTrackedOrder(uint256 orderId) external view returns (TrackedOrder memory) {
        return trackedOrders[orderId];
    }
    
    function getPairOrderCount(address pair) external view returns (uint256) {
        return pairOrderCount[pair];
    }
    
    function isPairSubscribed(address pair) external view returns (bool) {
        return subscribedPairs[pair];
    }
    
    function getPairOrders(address pair) external view returns (uint256[] memory) {
        return pairOrders[pair];
    }
}