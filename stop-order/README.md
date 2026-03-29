# Personal Uniswap V2 Stop Order System - A Reactive Smart Contract Demo

This project demonstrates a decentralized, permissionless, and automated **personal stop-order system** for Uniswap V2, built using Reactive Smart Contracts. Unlike shared systems, each user deploys their own private instance of both contracts, providing complete control, privacy, and customization over their stop orders.

The system allows users to create stop orders that automatically execute token swaps on Sepolia testnet when specific price thresholds are met, all orchestrated by personal logic contracts on the Reactive Network.

This implementation showcases the power of separating on-chain execution from off-chain event monitoring and logic, while maintaining user privacy and control through personal contract deployments.

## How It Works - The Complete Flow

The system's architecture is event-driven and operates across two blockchains, with each user having their own private contract instances:

1. **Personal Contract Deployment**:
   - Each user deploys their own `PersonalStopOrderCallback` contract on Sepolia
   - Each user deploys their own `PersonalStopOrderReactive` contract on the Reactive Network
   - The contracts are paired together and only serve that specific user

2. **User Preparation (on Sepolia)**:
   - Before creating orders, users must approve their personal `PersonalStopOrderCallback` contract to spend the tokens they wish to sell
   - This is a standard ERC20 `approve` transaction for each token

3. **Order Creation (on Sepolia)**:
   - Users call `createStopOrder` on their personal `PersonalStopOrderCallback` contract
   - The contract validates the order parameters and user's token balance/allowance
   - A `StopOrderCreated` event is emitted with all order details

4. **Reactive Processing & Subscription (on Reactive Network)**:
   - The personal `PersonalStopOrderReactive` contract automatically detects the order creation event
   - The contract processes the event, tracks the new order internally, and assigns it a unique `orderId`
   - If this is the first active order for a particular Uniswap pair, the contract automatically subscribes to the `Sync` events for that pair on Sepolia
   - Dynamic subscription ensures efficient resource usage - only monitoring pairs with active orders

5. **Automated Price Monitoring**:
   - The Reactive Network nodes listen for `Sync` events from subscribed Uniswap pairs on Sepolia
   - When price changes occur (indicated by `Sync` events), the event data is forwarded to the personal reactive contract's `react()` function

6. **Trigger Condition Assessment (on Reactive Network)**:
   - The reactive contract decodes reserve data from `Sync` events
   - It checks all active orders for that pair against the new price ratios
   - Orders have built-in cooldown periods and retry limits to prevent spam

7. **Cross-Chain Execution Trigger (Reactive Network → Sepolia)**:
   - When an order's price condition is met, the reactive contract emits a `Callback` event
   - This instructs the Reactive Network to call `executeStopOrder` on the user's personal callback contract on Sepolia
   - The order tracking is updated to prevent re-triggers

8. **Final Execution & Validation (on Sepolia)**:
   - The personal callback contract receives the execution request
   - It performs a final on-chain price validation as a security measure
   - It executes the token swap via Uniswap V2 router using pre-approved tokens
   - Received tokens are transferred directly back to the user's wallet

## Personal Contract Architecture

The system uses a personal deployment model with two contracts per user:

### 1. `PersonalStopOrderCallback.sol` (Execution Layer - Deployed on Sepolia)

**Purpose**: Personal execution contract that handles all stop order management and swap execution for a single user.

**Key Features**:
- **Order Management**: Create, cancel, pause, and resume stop orders
- **Swap Execution**: Handles actual token swaps through Uniswap V2 router
- **Safety Validations**: Final on-chain price checks before execution
- **Retry Logic**: Built-in retry mechanism with cooldown periods
- **Emergency Controls**: Owner can recover stuck tokens and withdraw ETH

**Order Lifecycle**:
- `Active`: Order is monitoring and can be triggered
- `Paused`: Order is temporarily disabled by user
- `Cancelled`: Order is permanently disabled by user
- `Executed`: Order has been successfully executed
- `Failed`: Order failed after maximum retry attempts

### 2. `PersonalStopOrderReactive.sol` (Logic Layer - Deployed on Reactive Network)

**Purpose**: Personal monitoring contract that tracks orders and triggers execution for a single user.

**Key Features**:
- **Event Monitoring**: Listens to stop order lifecycle events from the paired callback contract
- **Dynamic Subscriptions**: Automatically subscribes/unsubscribes to Uniswap pair events based on active orders
- **Price Monitoring**: Processes `Sync` events and evaluates trigger conditions
- **Order Tracking**: Maintains state for all orders with retry counts and cooldown periods
- **Cross-Chain Triggers**: Emits callbacks to trigger execution on Sepolia

## Key Features

- **Complete Privacy**: Each user has their own contract instances - no shared state or data
- **Non-Custodial**: Contracts never hold user funds except during atomic swap execution
- **Permissionless**: Anyone can deploy and use their own system instance
- **Efficient Monitoring**: Price monitoring handled off-chain by Reactive Network
- **Dynamic Resource Management**: Only monitors pairs with active orders
- **Comprehensive Order Management**: Support for pausing, resuming, and canceling orders
- **Retry & Error Handling**: Built-in retry logic with cooldown periods and failure states
- **Emergency Controls**: Users maintain full control over their contracts

## Environment Setup

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Environment Variables

Create a `.env` file:

```bash
# Private keys (NEVER share or commit these)
export SEPOLIA_PRIVATE_KEY=your_sepolia_private_key
export REACTIVE_PRIVATE_KEY=your_reactive_private_key

# Network RPC URLs
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Reactive Network's official callback sender address on Sepolia
export CALLBACK_SENDER_ADDR=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

# Sepolia Uniswap V2 addresses
export UNISWAP_V2_FACTORY=0x7E0987E5b3a30e3f2828572Bb659A548460a3003
export UNISWAP_V2_ROUTER=0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008

# Wallet addresses
export USER_WALLET_SEPOLIA=$(cast wallet address --private-key $SEPOLIA_PRIVATE_KEY)
export USER_WALLET_REACTIVE=$(cast wallet address --private-key $REACTIVE_PRIVATE_KEY)
```

### Project Setup

```bash
# Clone and navigate to project directory
git clone https://github.com/your-repo/personal-reactive-stop-orders.git
cd personal-reactive-stop-orders

# Install dependencies
forge install
```

## Personal System Deployment

Each user must deploy their own pair of contracts:

### Step 1: Deploy Personal Callback Contract (on Sepolia)

```bash
forge create --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY --broadcast \
  src/PersonalStopOrderCallback.sol:PersonalStopOrderCallback --value 0.01ether \
  --constructor-args $USER_WALLET_SEPOLIA $CALLBACK_SENDER_ADDR $UNISWAP_V2_ROUTER

# Save your personal callback address
export PERSONAL_CALLBACK_ADDR=0xYourPersonalCallbackAddress
echo "Personal Callback Contract deployed at: $PERSONAL_CALLBACK_ADDR"
```

### Step 2: Deploy Personal Reactive Contract (on Reactive Network)

```bash
forge create --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY --broadcast \
  src/PersonalStopOrderReactive.sol:PersonalStopOrderReactive --value 0.1ether \
  --constructor-args $USER_WALLET_REACTIVE $PERSONAL_CALLBACK_ADDR

# Save your personal reactive address
export PERSONAL_REACTIVE_ADDR=0xYourPersonalReactiveAddress
echo "Personal Reactive Contract deployed at: $PERSONAL_REACTIVE_ADDR"
```

## Using Your Personal Stop Order System

### Step 3: Approve Token Spending

Approve your personal callback contract to spend the tokens you want to trade:

```bash
# Example: Approve WETH spending
export WETH_ADDR=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 # Sepolia WETH
export APPROVE_AMOUNT=1000000000000000000 # 1 WETH

cast send $WETH_ADDR 'approve(address,uint256)' \
  $PERSONAL_CALLBACK_ADDR $APPROVE_AMOUNT \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

### Step 4: Create Stop Orders

Create stop orders on your personal callback contract:

```bash
# Create a stop order to sell WETH for USDC when WETH price drops 5%
export WETH_USDC_PAIR=0x4c4d5DFF92B35Df3293c46ACdf58FE0674940b64
export SELL_TOKEN0=true # WETH is token0
export SELL_AMOUNT=500000000000000000 # 0.5 WETH
export COEFFICIENT=1000000000000000000 # 1e18
export THRESHOLD=950000000000000000 # 0.95e18 (5% drop)

cast send $PERSONAL_CALLBACK_ADDR \
  'createStopOrder(address,bool,uint256,uint256,uint256)' \
  $WETH_USDC_PAIR $SELL_TOKEN0 $SELL_AMOUNT $COEFFICIENT $THRESHOLD \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

### Step 5: Manage Your Orders

```bash
# Pause order ID 0
cast send $PERSONAL_CALLBACK_ADDR 'pauseStopOrder(uint256)' 0 \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY

# Resume order ID 0
cast send $PERSONAL_CALLBACK_ADDR 'resumeStopOrder(uint256)' 0 \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY

# Cancel order ID 0
cast send $PERSONAL_CALLBACK_ADDR 'cancelStopOrder(uint256)' 0 \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

## Monitoring Your System

### Check Order Details

```bash
# Get details of order ID 0
cast call $PERSONAL_CALLBACK_ADDR 'getOrder(uint256)' 0 --rpc-url $SEPOLIA_RPC

# Get all your order IDs
cast call $PERSONAL_CALLBACK_ADDR 'getAllOrders()' --rpc-url $SEPOLIA_RPC

# Get only active orders
cast call $PERSONAL_CALLBACK_ADDR 'getActiveOrders()' --rpc-url $SEPOLIA_RPC
```

### Monitor Events

```bash
# Watch for new orders on your callback contract
cast logs --rpc-url $SEPOLIA_RPC $PERSONAL_CALLBACK_ADDR "StopOrderCreated"

# Watch for successful executions
cast logs --rpc-url $SEPOLIA_RPC $PERSONAL_CALLBACK_ADDR "StopOrderExecuted"

# Monitor reactive contract events
cast logs --rpc-url $REACTIVE_RPC $PERSONAL_REACTIVE_ADDR "ExecutionTriggered"
```

### Check System Status

```bash
# Check if a pair is subscribed for monitoring
export PAIR_ADDR=0x4c4d5DFF92B35Df3293c46ACdf58FE0674940b64
cast call $PERSONAL_REACTIVE_ADDR 'isPairSubscribed(address)' $PAIR_ADDR \
  --rpc-url $REACTIVE_RPC

# Get current price for reference
cast call $PERSONAL_CALLBACK_ADDR 'getCurrentPrice(address,bool)' $PAIR_ADDR true \
  --rpc-url $SEPOLIA_RPC
```

## Price Calculation

The system triggers when the calculated price ratio meets your threshold:

- **Selling token0**: Triggers when `(reserve1 * coefficient) / reserve0 <= threshold`
- **Selling token1**: Triggers when `(reserve0 * coefficient) / reserve1 <= threshold`

**Example**: To sell WETH (token0) when it drops 5%:
- Set `coefficient = 1e18`
- Set `threshold = 0.95e18`
- The order triggers when WETH price ≤ 95% of the coefficient-normalized price

## Emergency Functions

Your personal contracts include emergency functions for recovery:

```bash
# Recover stuck tokens from callback contract
cast send $PERSONAL_CALLBACK_ADDR \
  'emergencyRecoverToken(address,uint256)' $TOKEN_ADDR 0 \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY

# Withdraw ETH from contracts
cast send $PERSONAL_CALLBACK_ADDR \
  'withdrawAllETH(address)' $USER_WALLET_SEPOLIA \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

## Production Considerations

This personal system design offers enhanced security and privacy, but consider these improvements for production use:

1. **Enhanced Access Control**: Use multisig wallets for contract ownership
2. **Slippage Protection**: Implement minimum output amounts for swaps
3. **Gas Optimization**: Optimize for high-frequency order management
4. **Monitoring Dashboard**: Build a UI to track your personal system
5. **Backup Mechanisms**: Implement additional recovery methods
6. **Integration Testing**: Test cross-chain communication thoroughly

## Benefits of Personal Deployment Model

- **Complete Privacy**: Your orders and trading data are never shared
- **Customization**: Modify contracts to suit your specific needs
- **Independence**: No reliance on shared infrastructure or governance
- **Security**: Reduced attack surface with isolated contract instances
- **Control**: Full ownership and control over contract parameters and upgrades