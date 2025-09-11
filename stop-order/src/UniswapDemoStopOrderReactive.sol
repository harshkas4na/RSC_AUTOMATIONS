// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

import '../lib/reactive-lib/src/interfaces/IReactive.sol';
import '../lib/reactive-lib/src/abstract-base/AbstractReactive.sol';

struct Reserves {
    uint112 reserve0;
    uint112 reserve1;
}

struct StopOrder {
    address pair;
    address client;
    bool isToken0;
    uint256 coefficient;
    uint256 threshold;
    bool isActive;
    uint256 orderId;
}

contract UniswapDemoStopOrderReactive is IReactive, AbstractReactive {
    // Events for order management
    event StopOrderCreateRequested(
        uint256 indexed orderId,
        address indexed pair,
        address indexed client,
        bool isToken0,
        uint256 coefficient,
        uint256 threshold
    );

    event StopOrderCancelRequested(
        uint256 indexed orderId,
        address indexed client,
        address indexed pair 
    );

    event StopOrderCreated(
        uint256 indexed orderId,
        address indexed pair,
        address indexed client
    );

    event StopOrderCancelled(
        uint256 indexed orderId,
        address indexed client
    );

    event StopOrderTriggered(
        uint256 indexed orderId,
        address indexed pair,
        address indexed client
    );

    event CallbackSent(
        uint256 indexed orderId
    );

    event PairSubscribed(
        address indexed pair
    );

    event PairUnsubscribed(
        address indexed pair
    );

    // Constants
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 private constant REACTIVE_CHAIN_ID = 5318007;
    uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 private constant STOP_ORDER_STOP_TOPIC_0 = 0x9996f0dd09556ca972123b22cf9f75c3765bc699a1336a85286c7cb8b9889c6b;

    // Event topics for order management
    uint256 private constant CREATE_ORDER_TOPIC_0 = uint256(keccak256("StopOrderCreateRequested(uint256,address,address,bool,uint256,uint256)"));
    uint256 private constant CANCEL_ORDER_TOPIC_0 = uint256(keccak256("StopOrderCancelRequested(uint256,address,address)"));

    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    // State variables for ReactVM
    mapping(uint256 => StopOrder) private stopOrders; // orderId => StopOrder
    mapping(address => uint256[]) private clientOrders; // client => orderIds[]
    mapping(address => uint256) private pairOrderCount; // pair => active order count
    mapping(address => bool) private subscribedPairs; // pair => subscribed status

    uint256 private nextOrderId;
    address private stopOrderCallback;

    address private owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _stopOrderCallback,
        address _initialPair,
        bool _isToken0,
        uint256 _coefficient,
        uint256 _threshold
    ) payable {
        stopOrderCallback = _stopOrderCallback;
        nextOrderId = 1;
        owner = msg.sender;
        

        if (!vm) {
            // Subscribe to our own events for order management
            service.subscribe(
                REACTIVE_CHAIN_ID,
                address(this),
                CREATE_ORDER_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                REACTIVE_CHAIN_ID,
                address(this),
                CANCEL_ORDER_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Subscribe to callback contract events to track completion
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                _stopOrderCallback,
                STOP_ORDER_STOP_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Create the first stop order during deployment
            createFirstStopOrder(_initialPair, _isToken0, _coefficient, _threshold);
        }
    }

    // Internal function to create the first stop order during deployment
    function createFirstStopOrder(
        address pair,
        bool isToken0,
        uint256 coefficient,
        uint256 threshold
    ) internal {
        uint256 orderId = nextOrderId++;

        // Create the initial stop order directly in storage
        stopOrders[orderId] = StopOrder({
            pair: pair,
            client: owner,
            isToken0: isToken0,
            coefficient: coefficient,
            threshold: threshold,
            isActive: true,
            orderId: orderId
        });

        // Add to owner's orders
        clientOrders[owner].push(orderId);

        // Increment pair order count
        pairOrderCount[pair]++;

        // Subscribe to the pair immediately
        if (!subscribedPairs[pair]) {
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                pair,
                UNISWAP_V2_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
        }

        emit StopOrderCreated(orderId, pair, owner);
    }

    // Public functions for order management (called on Reactive Network)
    function createStopOrder(
        address pair,
        bool isToken0,
        uint256 coefficient,
        uint256 threshold
    ) external rnOnly{
        uint256 orderId = nextOrderId++;

        emit StopOrderCreateRequested(
            orderId,
            pair,
            msg.sender,
            isToken0,
            coefficient,
            threshold
        );
    }

    function cancelStopOrder(uint256 orderId, address pair) external rnOnly{
        emit StopOrderCancelRequested(orderId, msg.sender, pair);
    }

    // ReactVM event processing
    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == address(this)) {
            // Handle our own events
            if (log.topic_0 == CREATE_ORDER_TOPIC_0)
            {
                bytes memory payload_1 = abi.encodeWithSignature(
                    "processCreateOrder(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))",
                    address(0),
                    log
                );
                emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload_1);

                
            }
            else if (log.topic_0 == CANCEL_ORDER_TOPIC_0) {
                // Extract pair address directly from the event topic_3
               
                
                // First callback: Process the cancel order
                bytes memory payload_1 = abi.encodeWithSignature(
                    "processCancelOrder(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))",
                    address(0),
                    log
                );
                emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload_1);

                
            }
        }
        else if (log._contract == stopOrderCallback && log.topic_0 == STOP_ORDER_STOP_TOPIC_0) {
            // Handle stop order completion
             bytes memory payload_1 = abi.encodeWithSignature(
                    "processStopOrderCompletion(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))",
                    address(0),
                    log
                );
                emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload_1);
           
        } else if (log.topic_0 == UNISWAP_V2_SYNC_TOPIC_0 && subscribedPairs[log._contract]) {
            // Handle price updates for subscribed pairs
            processPriceUpdate(log);
            
        }
    }

    function processCreateOrder(address /*spender*/,LogRecord calldata log) external rnOnly{
        uint256 orderId = uint256(log.topic_1);
        address pair = address(uint160(log.topic_2));
        address client = address(uint160(log.topic_3));

        // Decode additional parameters from log data
        (bool isToken0, uint256 coefficient, uint256 threshold) = abi.decode(
            log.data,
            (bool, uint256, uint256)
        );

        // Create stop order
        stopOrders[orderId] = StopOrder({
            pair: pair,
            client: client,
            isToken0: isToken0,
            coefficient: coefficient,
            threshold: threshold,
            isActive: true,
            orderId: orderId
        });

        // Add to client's orders
        clientOrders[client].push(orderId);

        // Increment pair order count
        pairOrderCount[pair]++;

        if (!subscribedPairs[pair]) {
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                pair,
                UNISWAP_V2_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
        }

        emit StopOrderCreated(orderId, pair, client);
    }

    // Process cancel order events in ReactVM
    function processCancelOrder(address /*spender*/, LogRecord calldata log) external rnOnly {
        uint256 orderId = uint256(log.topic_1);
        address client = address(uint160(log.topic_2));
        address pair = address(uint160(log.topic_3));

        StopOrder storage order = stopOrders[orderId];
        require(order.isActive, "Order not active");
        require(order.client == client, "Not order owner");

        // Deactivate order
        order.isActive = false;

        // Decrement pair order count
        pairOrderCount[order.pair]--;

        if (subscribedPairs[pair] && pairOrderCount[pair] == 0) {
            service.unsubscribe(
                SEPOLIA_CHAIN_ID,
                pair,
                UNISWAP_V2_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            subscribedPairs[pair] = false;
            emit PairUnsubscribed(pair);
        }

        emit StopOrderCancelled(orderId, client);
    }

    // Process price updates for active pairs
    function processPriceUpdate(LogRecord calldata log) internal {
        address pair = log._contract;
        Reserves memory reserves = abi.decode(log.data, (Reserves));

        // Check all active orders for this pair
        for (uint256 i = 1; i < nextOrderId; i++) {
            StopOrder storage order = stopOrders[i];

            if (!order.isActive || order.pair != pair) {
                continue;
            }

            // Check if threshold is reached
            if (belowThreshold(order.isToken0, reserves, order.coefficient, order.threshold)) {
                // Trigger stop order
                triggerStopOrder(order, log.chain_id);

                // Deactivate order to prevent multiple triggers
                order.isActive = false;
                pairOrderCount[pair]--;

                emit StopOrderTriggered(order.orderId, pair, order.client);
            }
        }
    }

    // Process stop order completion events
    function processStopOrderCompletion(address /*sender*/, LogRecord calldata log) external  {
        // Extract order completion data from log
        uint256 orderId = uint256(log.topic_1);
        address pair = address(uint160(log.topic_2));
        address client = address(uint160(log.topic_3));

        // Find the order and mark it as completed/inactive
        StopOrder storage order = stopOrders[orderId];
        if (order.isActive && order.pair == pair && order.client == client) {
            // Mark order as inactive since it executed successfully
            order.isActive = false;
            pairOrderCount[pair]--;

            // Unsubscribe from pair if no more active orders
            if (subscribedPairs[pair] && pairOrderCount[pair] == 0) {
                service.unsubscribe(
                    SEPOLIA_CHAIN_ID,
                    pair,
                    UNISWAP_V2_SYNC_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                subscribedPairs[pair] = false;
                emit PairUnsubscribed(pair);
            }
        }
    }

    // Trigger stop order execution
    function triggerStopOrder(StopOrder memory order, uint256 chainId) internal {
        bytes memory payload = abi.encodeWithSignature(
            "stop(address,address,address,bool,uint256,uint256)",
            address(0),
            order.pair,
            order.client,
            order.isToken0,
            order.coefficient,
            order.threshold
        );

        emit Callback(chainId, stopOrderCallback, CALLBACK_GAS_LIMIT, payload);
        emit CallbackSent(order.orderId);
    }

   

   

    // Threshold checking logic
    function belowThreshold(
        bool isToken0,
        Reserves memory reserves,
        uint256 coefficient,
        uint256 threshold
    ) internal pure returns (bool) {
        if (isToken0) {
            return (reserves.reserve1 * coefficient) / reserves.reserve0 <= threshold;
        } else {
            return (reserves.reserve0 * coefficient) / reserves.reserve1 <= threshold;
        }
    }

    // View functions for order management
    function getOrder(uint256 orderId) external view returns (StopOrder memory) {
        return stopOrders[orderId];
    }

    function getClientOrders(address client) external view returns (uint256[] memory) {
        return clientOrders[client];
    }

    function getActiveOrdersForPair(address pair) external view returns (uint256[] memory) {
        uint256[] memory activeOrders = new uint256[](pairOrderCount[pair]);
        uint256 count = 0;

        for (uint256 i = 1; i < nextOrderId; i++) {
            if (stopOrders[i].isActive && stopOrders[i].pair == pair) {
                activeOrders[count] = i;
                count++;
            }
        }

        return activeOrders;
    }

    function isPairSubscribed(address pair) external view returns (bool) {
        return subscribedPairs[pair];
    }

    function withdrawETH(uint256 amount) external onlyOwner {
    require(amount > 0, "Amount must be greater than 0");
    require(amount <= address(this).balance, "Insufficient contract balance");
    
    payable(owner).transfer(amount);
}

// Optional: Keep the old function that withdraws everything
function withdrawAllETh() external onlyOwner {
    require(address(this).balance > 0, "No balance to withdraw");
    payable(owner).transfer(address(this).balance);
}
}