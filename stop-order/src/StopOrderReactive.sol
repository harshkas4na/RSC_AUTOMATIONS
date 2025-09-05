// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

import '../lib/reactive-lib/src/interfaces/IReactive.sol';
import '../lib/reactive-lib/src/abstract-base/AbstractReactive.sol';

struct Reserves {
    uint112 reserve0;
    uint112 reserve1;
}

enum OrderStatus {
    Active,
    Cancelled,
    Executed,
    Failed
}

struct StopOrder {
    address pair;
    address client;
    bool token0;
    uint256 coefficient;
    uint256 threshold;
    OrderStatus status;
    bool triggered;
    uint256 createdAt;
    uint256 updatedAt;
}

contract UniswapDemoStopOrderReactive is IReactive, AbstractReactive {
    event StopOrderCreated(
        uint256 indexed orderId,
        address indexed pair,
        address indexed client,
        bool token0,
        uint256 coefficient,
        uint256 threshold
    );

    event StopOrderCancelled(
        uint256 indexed orderId,
        address indexed client
    );

    event CallbackSent(uint256 indexed orderId);
    event OrderCompleted(uint256 indexed orderId);
    event OrderFailed(uint256 indexed orderId, string reason);
    
    // Withdrawal events
    event ETHWithdrawn(address indexed to, uint256 amount);

    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 private constant STOP_ORDER_STOP_TOPIC_0 = 0x9996f0dd09556ca972123b22cf9f75c3765bc699a1336a85286c7cb8b9889c6b;
    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    // Access control
    address private deployer;

    // State specific to ReactVM instance of the contract.
    mapping(uint256 => StopOrder) public stopOrders;
    mapping(address => uint256[]) public userActiveOrders;
    mapping(address => uint256[]) public userExecutedOrders;
    mapping(address => uint256[]) public userCancelledOrders;
    mapping(address => uint256[]) public userFailedOrders;
    
    uint256 public nextOrderId;
    address private stop_order_callback;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer can call this function");
        _;
    }

    constructor(
        address _pair,
        address _stop_order_callback,
        address _client,
        bool _token0,
        uint256 _coefficient,
        uint256 _threshold
    ) payable {
        deployer = msg.sender;
        stop_order_callback = _stop_order_callback;
        nextOrderId = 1; // Start from 1, not 0
        _createStopOrder(_pair, _client, _token0, _coefficient, _threshold);
    }

    function createStopOrder(
        address _pair,
        address _client,
        bool _token0,
        uint256 _coefficient,
        uint256 _threshold
    ) external onlyDeployer returns (uint256 orderId) {
        require(_client != address(0), "Invalid client address");
        require(_pair != address(0), "Invalid pair address");
        require(_coefficient > 0, "Coefficient must be greater than 0");
        require(_threshold > 0, "Threshold must be greater than 0");
        
        return _createStopOrder(_pair, _client, _token0, _coefficient, _threshold);
    }

    function _createStopOrder(
        address _pair,
        address _client,
        bool _token0,
        uint256 _coefficient,
        uint256 _threshold
    ) internal returns (uint256 orderId) {
        orderId = nextOrderId;
        nextOrderId++;

        stopOrders[orderId] = StopOrder({
            pair: _pair,
            client: _client,
            token0: _token0,
            coefficient: _coefficient,
            threshold: _threshold,
            status: OrderStatus.Active,
            triggered: false,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });
        
        userActiveOrders[_client].push(orderId);
        
        // Each order gets its own subscription
        if (!vm) {
            // Subscribe to pair sync events for this specific order
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                _pair,
                UNISWAP_V2_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            // Subscribe to callback events for execution confirmation
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                stop_order_callback,
                STOP_ORDER_STOP_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        emit StopOrderCreated(orderId, _pair, _client, _token0, _coefficient, _threshold);
    }

    function cancelStopOrder(uint256 orderId) external onlyDeployer {
        require(stopOrders[orderId].client != address(0), "Order does not exist");
        require(stopOrders[orderId].status == OrderStatus.Active, "Order not active");
        require(!stopOrders[orderId].triggered, "Order already triggered");
        
        StopOrder storage order = stopOrders[orderId];
        address pairToCheck = order.pair;
        address clientToUpdate = order.client;
        
        order.status = OrderStatus.Cancelled;
        order.updatedAt = block.timestamp;
        
        // Remove from active orders and add to cancelled orders
        _removeFromUserActiveOrders(clientToUpdate, orderId);
        userCancelledOrders[clientToUpdate].push(orderId);
        
        // Only unsubscribe from pair if no other active orders exist for this pair
        if (!vm && !_hasActiveOrdersForPair(pairToCheck)) {
            service.unsubscribe(
                SEPOLIA_CHAIN_ID,
                pairToCheck,
                UNISWAP_V2_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        
        emit StopOrderCancelled(orderId, clientToUpdate);
    }

    // Emergency withdrawal functions - only deployer can call
    function withdrawETH(address payable to, uint256 amount) external onlyDeployer {
        require(to != address(0), "Invalid recipient address");
        require(amount <= address(this).balance, "Insufficient ETH balance");
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit ETHWithdrawn(to, amount);
    }


    function withdrawAllETH(address payable to) external onlyDeployer {
        require(to != address(0), "Invalid recipient address");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH transfer failed");
        
        emit ETHWithdrawn(to, balance);
    }

  

    function _removeFromUserActiveOrders(address user, uint256 orderId) internal {
        uint256[] storage activeOrders = userActiveOrders[user];
        for (uint256 i = 0; i < activeOrders.length; i++) {
            if (activeOrders[i] == orderId) {
                activeOrders[i] = activeOrders[activeOrders.length - 1];
                activeOrders.pop();
                break;
            }
        }
    }

    // Helper function to check if there are any active orders for a specific pair
    function _hasActiveOrdersForPair(address pair) internal view returns (bool) {
        for (uint256 i = 1; i < nextOrderId; i++) {
            if (stopOrders[i].status == OrderStatus.Active && 
                !stopOrders[i].triggered && 
                stopOrders[i].pair == pair) {
                return true;
            }
        }
        return false;
    }

    // Helper function to check if there are any active orders at all
    function _hasAnyActiveOrders() internal view returns (bool) {
        for (uint256 i = 1; i < nextOrderId; i++) {
            if (stopOrders[i].status == OrderStatus.Active && 
                !stopOrders[i].triggered) {
                return true;
            }
        }
        return false;
    }

    // View functions for different order categories
    function getUserActiveOrders(address user) external view returns (uint256[] memory) {
        return userActiveOrders[user];
    }

    function getUserExecutedOrders(address user) external view returns (uint256[] memory) {
        return userExecutedOrders[user];
    }

    function getUserCancelledOrders(address user) external view returns (uint256[] memory) {
        return userCancelledOrders[user];
    }

    function getUserFailedOrders(address user) external view returns (uint256[] memory) {
        return userFailedOrders[user];
    }

    function getAllUserOrders(address user) external view returns (
        uint256[] memory active,
        uint256[] memory executed,
        uint256[] memory cancelled,
        uint256[] memory failed
    ) {
        return (
            userActiveOrders[user],
            userExecutedOrders[user],
            userCancelledOrders[user],
            userFailedOrders[user]
        );
    }

    function getStopOrder(uint256 orderId) external view returns (StopOrder memory) {
        return stopOrders[orderId];
    }

    // View function to check deployer address
    function getDeployer() external view returns (address) {
        return deployer;
    }

    

    // Methods specific to ReactVM instance of the contract.
    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == stop_order_callback) {
            // Handle stop order execution results
            if (log.topic_0 == STOP_ORDER_STOP_TOPIC_0) {
                // The Stop event structure: Stop(address indexed pair, address indexed client, address indexed token, uint256 orderId, uint256[] tokens)
                // We need to extract orderId from the data field since it's not indexed
                // The data contains: orderId (uint256) + tokens[] (dynamic array)
                
                // Decode the data to extract orderId and tokens
                (uint256 orderId, uint256[] memory tokens) = abi.decode(log.data, (uint256, uint256[]));
                
                StopOrder storage order = stopOrders[orderId];
                
                if (order.triggered && order.status == OrderStatus.Active) {
                    address pairToCheck = order.pair;
                    // Mark as executed and clean up
                    order.status = OrderStatus.Executed;
                    order.updatedAt = block.timestamp;
                    
                    // Move from active to executed
                    _removeFromUserActiveOrders(order.client, orderId);
                    userExecutedOrders[order.client].push(orderId);
                    
                    // Only unsubscribe from pair if no other active orders exist for this pair
                    if (!_hasActiveOrdersForPair(pairToCheck)) {
                        service.unsubscribe(
                            SEPOLIA_CHAIN_ID,
                            pairToCheck,
                            UNISWAP_V2_SYNC_TOPIC_0,
                            REACTIVE_IGNORE,
                            REACTIVE_IGNORE,
                            REACTIVE_IGNORE
                        );
                    }
                    
                    // Only unsubscribe from callback contract if no active orders remain at all
                    if (!_hasAnyActiveOrders()) {
                        service.unsubscribe(
                            SEPOLIA_CHAIN_ID,
                            stop_order_callback,
                            STOP_ORDER_STOP_TOPIC_0,
                            REACTIVE_IGNORE,
                            REACTIVE_IGNORE,
                            REACTIVE_IGNORE
                        );
                    }
                    
                    emit OrderCompleted(orderId);
                }
            }
        } else {
            // Handle sync events from Uniswap pairs
            Reserves memory sync = abi.decode(log.data, (Reserves));
            
            // Check all active orders for this pair
            for (uint256 i = 1; i < nextOrderId; i++) {
                StopOrder storage order = stopOrders[i];
                
                if (order.status == OrderStatus.Active && 
                    !order.triggered && 
                    order.pair == log._contract &&
                    below_threshold(order, sync)) {
                    
                    emit CallbackSent(i);
                    bytes memory payload = abi.encodeWithSignature(
                        "stop(address,address,address,bool,uint256,uint256,uint256)",
                        address(0),
                        order.pair,
                        order.client,
                        order.token0,
                        order.coefficient,
                        order.threshold,
                        i
                    );
                    order.triggered = true;
                    order.updatedAt = block.timestamp;
                    emit Callback(log.chain_id, stop_order_callback, CALLBACK_GAS_LIMIT, payload);
                }
            }
        }
    }

    function below_threshold(StopOrder memory order, Reserves memory sync) internal pure returns (bool) {
        if (order.token0) {
            return (sync.reserve1 * order.coefficient) / sync.reserve0 <= order.threshold;
        } else {
            return (sync.reserve0 * order.coefficient) / sync.reserve1 <= order.threshold;
        }
    }

}