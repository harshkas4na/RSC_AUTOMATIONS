
# Uniswap V2 Stop Order System - A Reactive Smart Contract Demo

This project demonstrates a decentralized, permissionless, and automated stop-order system for Uniswap V2, built using Reactive Smart Contracts. The system allows any user to create stop orders that automatically execute token swaps on the Sepolia testnet when specific price thresholds are met, all orchestrated by a logic contract on the Reactive Network.

This implementation showcases the power of separating on-chain execution from off-chain event monitoring and logic, creating a highly efficient and scalable DeFi primitive.

## How It Works - The Complete Flow

The system's architecture is event-driven and operates across two blockchains: the Reactive Network (for logic) and a target EVM chain like Sepolia (for execution).

1.  **User Preparation (on Sepolia)**:

      * Before creating an order, a user must approve the `UniswapDemoStopOrderCallback` contract to spend the specific token they wish to sell. This is a standard ERC20 `approve` transaction and is a crucial prerequisite.

2.  **Order Creation (on Reactive Network)**:

      * A user calls the `createStopOrder` function on the `UniswapDemoStopOrderReactive` contract. This is a permissionless action—anyone can create an order for their own wallet.
      * The function emits a `StopOrderCreateRequested` event. The system is designed to react to its own events for state changes.

3.  **Reactive Processing & Subscription (on Reactive Network)**:

      * The Reactive VM detects the creation event and calls the `react()` function on the reactive contract.
      * The contract processes the event, saves the new `StopOrder` to its state, and assigns it a unique `orderId`.
      * If this is the first active order for a particular Uniswap pair, the contract automatically sends a request to the Reactive Network's service layer to subscribe to the `Sync` event for that pair on Sepolia. This ensures the system only monitors pairs with active orders, saving resources.

4.  **Automated Price Monitoring (Off-Chain)**:

      * The Reactive Network nodes listen for `Sync` events on Sepolia from all subscribed pairs.
      * When a `Sync` event occurs (indicating a trade and a change in reserves), the event data is securely forwarded to the `react()` function of the reactive contract.

5.  **Trigger Condition Met (on Reactive Network)**:

      * Inside the `react()` function, the contract decodes the new reserve data from the `Sync` event.
      * It iterates through all active orders for that pair and checks if the new price ratio has crossed any order's threshold.

6.  **Cross-Chain Execution (Reactive Network -\> Sepolia)**:

      * If an order's condition is met, the reactive contract triggers a cross-chain `Callback`.
      * This `Callback` is an instruction for the Reactive Network to call the `stop()` function on the `UniswapDemoStopOrderCallback` contract on Sepolia, passing all the necessary order details.
      * The order is immediately marked as inactive in the reactive contract to prevent re-triggers.

7.  **Final On-Chain Swap (on Sepolia)**:

      * The `UniswapDemoStopOrderCallback` contract receives the call.
      * As a final security measure, it re-validates the price condition against the current on-chain reserves.
      * It uses its pre-approved allowance to pull tokens from the user's wallet via `transferFrom`.
      * It executes the swap on Uniswap V2.
      * The resulting tokens are transferred directly back to the user's wallet.

## Contract Architecture

The system consists of two main smart contracts, demonstrating a clear separation of concerns:

### 1\. `UniswapDemoStopOrderCallback.sol` (Execution Layer - Deployed on Sepolia)

  * **Purpose**: The "hands" of the system. It holds no state about orders.
  * **Execution**: Handles the actual token swap through the Uniswap V2 router. It is the only contract that requires token approval from the user.
  * **Validation**: Performs a final, on-chain price check before executing the swap to protect against stale data or front-running.
  * **Security**: Can be paused by the owner in an emergency. Includes functions for the owner to recover any accidentally sent tokens.

### 2\. `UniswapDemoStopOrderReactive.sol` (Logic Layer - Deployed on Reactive Network)

  * **Purpose**: The "brain" of the system. It manages all order states and logic.
  * **Order Management**: Allows any user to create and cancel their own stop orders. It maintains the state of all active orders.
  * **Dynamic Subscriptions**: Intelligently subscribes and unsubscribes to Uniswap pair events on Sepolia based on whether there are active orders for those pairs.
  * **Event Handling**: The core `react()` function processes events for order creation, cancellation, and price updates (`Sync` events).

## Key Features

  * **Permissionless & Non-Custodial**: Any user can interact with the system. The contracts never take custody of user funds except for the atomic moment of the swap.
  * **Efficient Off-Chain Monitoring**: Price monitoring is handled by the Reactive Network, meaning users don't pay gas for constant on-chain checks. Gas is only spent on Sepolia for the final swap execution.
  * **Multi-User & Multi-Order Support**: A single deployment of these contracts can serve an unlimited number of users and orders across any Uniswap V2 pair.
  * **Dynamic Resource Management**: The event subscription model is highly efficient, ensuring the system's workload scales directly with its usage.
  * **Event-Driven & Asynchronous**: The system is fully asynchronous, reacting to on-chain events as they occur, making it robust and scalable.

## Environment Setup

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Environment Variables

Create a `.env` file or export the following variables:

```bash
# Private keys (NEVER share or commit these)
export SEPOLIA_PRIVATE_KEY=
export REACTIVE_PRIVATE_KEY=

# Network RPC URLs
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Reactive Network's official callback sender address on Sepolia
export CALLBACK_SENDER_ADDR=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

# Sepolia Uniswap V2 addresses (or use your own deployment)
export UNISWAP_V2_FACTORY=0x7E0987E5b3a30e3f2828572Bb659A548460a3003
export UNISWAP_V2_ROUTER=0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008

# Wallet addresses (will be determined automatically by scripts)
export USER_WALLET_SEPOLIA=$(cast wallet address --private-key $SEPOLIA_PRIVATE_KEY)
export USER_WALLET_REACTIVE=$(cast wallet address --private-key $REACTIVE_PRIVATE_KEY)
```

### Project Setup

```bash
# Clone and navigate to project directory
git clone https://github.com/your-repo/reactive-uniswap-stop-order.git
cd reactive-uniswap-stop-order

# Install dependencies using forge
forge install
```

## Deployment and Usage Guide

**(Optional: If you need to deploy your own test tokens and Uniswap pair, follow these steps. Otherwise, you can use existing pairs on Sepolia.)**

### Step 1: Deploy Callback Contract (on Sepolia)

This contract executes the swaps. It needs to know the address of the Reactive Network's official callback sender to authorize calls.

```bash
forge create --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY --via-ir --broadcast \
  src/UniswapDemoStopOrderCallback.sol:UniswapDemoStopOrderCallback --value 0.01\
  --constructor-args $CALLBACK_SENDER_ADDR $UNISWAP_V2_ROUTER 

# Save the deployed address
export CALLBACK_ADDR=0x2A94C2E24185733f380801a661DE039E9DEdAB9A
echo "Callback Contract deployed at: $CALLBACK_ADDR"
```

### Step 2: Deploy Reactive Contract (on Reactive Network)

This contract contains the logic. It needs to know the address of the Callback Contract it will be triggering on Sepolia.

```bash
# Set initial stop order parameters for deployment
export INITIAL_PAIR_ADDRESS=0x4c4d5DFF92B35Df3293c46ACdf58FE0674940b64 # Address of the  pair on Sepolia
export INITIAL_IS_TOKEN0=true
export INITIAL_COEFFICIENT=1000000000000000000 # 1e18
export INITIAL_THRESHOLD=990000000000000000    # 0.99e18

forge create --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY --broadcast \
  src/UniswapDemoStopOrderReactive.sol:UniswapDemoStopOrderReactive --value 0.1ether \
  --constructor-args $CALLBACK_ADDR $INITIAL_PAIR_ADDRESS $INITIAL_IS_TOKEN0 $INITIAL_COEFFICIENT $INITIAL_THRESHOLD

# Save the deployed address
export REACTIVE_ADDR=0x2B53e421344aAf5dF1788faB095a3DbEa897AE9d
echo "Reactive Contract deployed at: $REACTIVE_ADDR"
echo "First stop order (ID: 1) created automatically during deployment"
```

### Step 3: Approve Token Spending (User Action on Sepolia)

To create a stop order to sell WETH for DAI, you must first approve the deployed `CALLBACK_ADDR` to spend your WETH.

```bash
# Example: Approve 10 WETH
export WETH_ADDR=0xAEa693033F63A3403Ce3D0ea3C7D01E88AFF63c0 # Sepolia WETH
export TOKEN_SELL_AMOUNT=10000000000000000000 # 10 tokens with 18 decimals

cast send $WETH_ADDR 'approve(address,uint256)' \
  $CALLBACK_ADDR $TOKEN_SELL_AMOUNT \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

### Step 4: Create a Stop Order (User Action on Reactive Network)

Now, create the order on the Reactive Network. `msg.sender` of this transaction will be the order's owner (`client`).

```bash
export PAIR_ADDRESS=0x96047849687C967c3402C615a1c5F5194582d363 # Address of the  pair on Sepolia
# Let's say WETH is token0 and we want to sell if price drops 5% (ratio < 0.95)
export IS_TOKEN0=true
export COEFFICIENT=1000000000000000000 # 1e18
export THRESHOLD=999000000000000000    # 0.999e17

cast send $REACTIVE_ADDR 'createStopOrder(address,bool,uint256,uint256)' \
  $PAIR_ADDRESS $IS_TOKEN0 $COEFFICIENT $THRESHOLD \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

Your order is now live. The Reactive Network will monitor the pair and execute the swap on your behalf if the price condition is met.

### Step 5: Cancel a Stop Order (User Action on Reactive Network)

Only the original creator of an order can cancel it. You will need the `orderId` (which starts at 1 and increments).

```bash
# Cancel the first order (orderId = 1) - now requires pair address
export ORDER_ID=1
export PAIR_ADDRESS=0x4c4d5DFF92B35Df3293c46ACdf58FE0674940b64 # The pair address for this order

cast send $REACTIVE_ADDR 'cancelStopOrder(uint256,address)' $ORDER_ID $PAIR_ADDRESS \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

## Monitoring and Interaction

### Check Order Details

```bash
# Get details of order with ID 1
cast call $REACTIVE_ADDR 'getOrder(uint256)' 1 --rpc-url $REACTIVE_RPC
```

### Check a User's Orders

```bash
# Get all order IDs for a specific client address
cast call $REACTIVE_ADDR 'getClientOrders(address)' $USER_WALLET_REACTIVE \
  --rpc-url $REACTIVE_RPC
```

### Monitor Events

```bash
# Watch for new orders being created on the Reactive Network
cast logs --rpc-url $REACTIVE_RPC $REACTIVE_ADDR "StopOrderCreateRequested"

# Watch for successful swaps on Sepolia
cast logs --rpc-url $SEPOLIA_RPC $CALLBACK_ADDR "Stop"
```

## Price Calculation Explained

The system triggers when the ratio of reserves falls below your threshold.

  - To sell `token0` (e.g., WETH in a  pair):
      - The condition is `(reserve1 * coefficient) / reserve0 <= threshold`.
      - This effectively checks if `(price of token0 in terms of token1) <= threshold / coefficient`.
  - To sell `token1` (e.g., DAI in a  pair):
      - The condition is `(reserve0 * coefficient) / reserve1 <= threshold`.
      - This checks if `(price of token1 in terms of token0) <= threshold / coefficient`.

**Example**: For a 5% price drop when selling `token0`, set `coefficient` to `1e18` and `threshold` to `0.95e18`.

## Production Considerations

This project is a demonstration. For a production-ready system, consider the following enhancements:

1.  **Slippage Protection**: The current `swapExactTokensForTokens` call sets `amountOutMin` to 0. A production version must calculate and enforce a minimum output to protect against slippage and MEV.
2.  **Robust Access Control**: While order creation is permissionless, contract ownership (`owner`) should be managed by a multisig or a DAO for security.
3.  **Fee Structure**: Introduce a protocol fee on swaps to ensure long-term sustainability.
4.  **Error Handling**: Enhance event emission to provide more detailed reasons for failed orders (`StopOrderFailed` event).
5.  **Gas Optimization**: Further optimize data structures and logic for high-volume usage.