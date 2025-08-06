# Uniswap V2 Stop Order System with RSC

This project provides an automated stop order system for Uniswap V2 using Reactive Smart Contracts (RSC). The system allows users to create stop orders that automatically execute token swaps when price thresholds are reached, without requiring manual intervention.

## How It Works - The Complete Flow

This system creates a seamless stop order experience:

1. **Order Creation on Sepolia**:
   - Users create stop orders on the Sepolia chain
   - Orders include token pair, amount, direction, and price threshold
   - System validates user balance and allowances
   - Order creation event is emitted

2. **Dynamic Event Monitoring**:
   - RSC contract detects new stop order events
   - Dynamically subscribes to relevant Uniswap V2 pair events
   - Only monitors pairs with active orders for gas efficiency
   - Manages multiple orders with proper state tracking

3. **Automated Price Monitoring**:
   - RSC monitors Sync events from Uniswap V2 pairs
   - Calculates current price ratios using reserve data
   - Compares against user-defined thresholds
   - Implements cooldown periods to prevent spam

4. **Smart Order Execution**:
   - When price conditions are met, RSC triggers callback
   - Callback contract validates conditions and executes swap
   - Includes retry logic for failed transactions
   - Handles edge cases like insufficient balance/allowance

5. **Comprehensive Order Management**:
   - Users can pause, resume, or cancel orders
   - System tracks order status and execution history
   - Automatic cleanup when orders complete or fail
   - Dynamic unsubscription when no orders remain for a pair

## Contract Architecture

The system consists of two main contracts:

### 1. StopOrderCallback (Sepolia Chain)
- **Order Management**: Create, cancel, pause, resume stop orders
- **Execution Logic**: Handles actual token swaps through Uniswap router
- **State Tracking**: Maintains order status and execution history
- **Safety Features**: Balance/allowance checks, retry logic, error handling
- **Event Emission**: Emits events for RSC to monitor

### 2. StopOrderReactive (Reactive Network)
- **Event Monitoring**: Listens for stop order lifecycle events
- **Dynamic Subscriptions**: Only subscribes to pairs with active orders
- **Price Monitoring**: Processes Uniswap Sync events for price changes
- **Trigger Logic**: Determines when to execute orders based on thresholds
- **State Management**: Tracks multiple orders with proper status handling

## Key Features

### Advanced Order Management
- **Multiple Order Support**: Handle unlimited orders per user
- **Directional Trading**: Support both token0→token1 and token1→token0 swaps
- **Flexible Thresholds**: Custom price coefficients and thresholds
- **Order Lifecycle**: Complete pause/resume/cancel functionality

### Robust Execution Engine
- **Retry Logic**: Failed orders retry up to 3 times with cooldown
- **Gas Optimization**: Cooldown periods prevent excessive gas usage
- **Balance Protection**: Real-time balance and allowance verification
- **Slippage Handling**: Accepts any amount out (configurable in production)

### Dynamic Resource Management
- **Smart Subscriptions**: Only monitor pairs with active orders
- **Automatic Cleanup**: Unsubscribe when no orders remain
- **Memory Efficiency**: Optimized data structures for gas efficiency
- **Event Filtering**: Process only relevant events

### Safety & Security
- **Access Control**: Order owners can only manage their orders
- **Input Validation**: Comprehensive validation of all parameters
- **Error Recovery**: Graceful handling of failed transactions
- **Reentrancy Protection**: Safe state management patterns

## Environment Setup

### Prerequisites
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Environment Variables
Set up the required environment variables:

```bash
# Private key (NEVER share or commit this)
export PRIVATE_KEY=your_private_key

# Network RPC URLs
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
export REACTIVE_RPC_URL=https://lasna-rpc.rnk.dev/

# Contract addresses
export UNISWAP_V2_ROUTER=0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
export REACTIVE_CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

# Deployer wallet address
export CLIENT_WALLET=0x941b727Ad8ACF020558Ce58CD7Cb65b48B958DB1
```

### Project Setup
```bash
# Clone and navigate to project directory
git clone https://github.com/yourusername/stop-order-system.git
cd stop-order-system

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install Uniswap/v2-core
forge install Uniswap/v2-periphery
forge install Reactive-Network/reactive-lib --no-commit

# Generate remappings
forge remappings > remappings.txt
```

## Deployment Process

### Step 1: Deploy the Stop Order Callback Contract (Sepolia)

#### Option A: Using Foundry Script (Recommended)
```bash
# Deploy using the deployment script
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# Save the deployed callback address from output
export CALLBACK_ADDRESS=0x9148309eFB90b8803187413DFEE904327DFD8835  # Replace with deployed address
```

#### Option B: Manual Deployment
```bash
forge create --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  src/StopOrderCallback.sol:StopOrderCallback --via-ir --broadcast --value 0.01ether \
  --constructor-args $REACTIVE_CALLBACK_PROXY $UNISWAP_V2_ROUTER \
  

# Save the deployed callback address
export CALLBACK_ADDRESS=0x...  # Replace with deployed address
```

### Step 3: Deploy the RSC Contract (Reactive Network)

Deploy the RSC contract that will monitor events and trigger executions:

```bash
forge create --legacy --rpc-url $REACTIVE_RPC_URL --private-key $PRIVATE_KEY \
  src/StopOrderReactive.sol:StopOrderReactive --value 0.01ether --broadcast \
  --constructor-args $CALLBACK_ADDRESS \
  
```

Save the deployed RSC address:
```bash
export RSC_ADDRESS=0x...  # Replace with deployed address
```

### Step 4: Verify Deployment

Check that both contracts are deployed correctly:

```bash
# Check callback contract
cast call $CALLBACK_ADDRESS "router()(address)" --rpc-url $SEPOLIA_RPC_URL

# Check RSC contract
cast call $RSC_ADDRESS "react()" --rpc-url $REACTIVE_RPC_URL
```

## Using the Stop Order System

### Step 1: Prepare Test Tokens (If Needed)

#### Option A: Using Deployment Script (Recommended)
```bash
# Deploy test tokens using script
forge script script/Deploy.s.sol:DeployScript --sig "deployTestTokens()" \
  --rpc-url $SEPOLIA_RPC_URL --broadcast

# Save the token addresses from output
export TOKEN1=0x...  # Replace with deployed address
export TOKEN2=0x...  # Replace with deployed address
```

#### Option B: Manual Token Deployment
```bash
# Deploy test token 1
forge create --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  test/TestToken.sol:TestToken --broadcast \
  --constructor-args "Test Token 1" "TK1" 18 1000000000000000000000

export TOKEN1=0x...  # Replace with deployed address

# Deploy test token 2
forge create --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  test/TestToken.sol:TestToken --broadcast \
  --constructor-args "Test Token 2" "TK2" 18 1000000000000000000000

export TOKEN2=0x...  # Replace with deployed address
```

#### Option C: Use Existing Tokens
```bash
# Use existing test tokens (example addresses)
export TOKEN1=0xAEa693033F63A3403Ce3D0ea3C7D01E88AFF63c0
export TOKEN2=0x291eC3425647af3b022d46df4Fa81b45e0b47f46
```

### Step 2: Create or Use Existing Uniswap Pair

Find or create a Uniswap V2 pair for your tokens:

```bash
# Example pair addresses (replace with actual pairs)
export PAIR_ADDRESS=0x58078D5eC354d39a54BFDf32ac3eaF001ebBcA07
```

To create a new pair:
```bash
# Create pair using Uniswap V2 Factory
cast send 0x7E0987E5b3a30e3f2828572Bb659A548460a3003 \
  'createPair(address,address)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $TOKEN1 $TOKEN2

# Add liquidity to the pair
cast send $TOKEN1 'transfer(address,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $PAIR_ADDRESS 10000000000000000000

cast send $TOKEN2 'transfer(address,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $PAIR_ADDRESS 10000000000000000000

cast send $PAIR_ADDRESS 'mint(address)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $CLIENT_WALLET
```

### Step 3: Approve Token Spending

Approve the callback contract to spend your tokens:

```bash
# Approve token spending (example: 100 tokens)
cast send $TOKEN1 'approve(address,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $CALLBACK_ADDRESS 100000000000000000000
```

### Step 4: Create a Stop Order

Create your first stop order:

```bash
# Example: Sell 10 TOKEN1 for TOKEN2 if price drops 10%
# Parameters: pair, sellToken0, amount, coefficient, threshold
cast send $CALLBACK_ADDRESS \
  'createStopOrder(address,bool,uint256,uint256,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $PAIR_ADDRESS true 10000000000000000000 1000 900
```

The parameters explained:
- `pair`: The Uniswap V2 pair address
- `sellToken0`: `true` to sell token0, `false` to sell token1
- `amount`: Amount of tokens to sell (in wei)
- `coefficient`: Price calculation coefficient (e.g., 1000)
- `threshold`: Price threshold that triggers the order (e.g., 900 = 90% of original)

### Step 5: Monitor Your Orders

Check your orders:

```bash
# Get user orders
cast call $CALLBACK_ADDRESS 'getUserOrders(address)(uint256[])' \
  --rpc-url $SEPOLIA_RPC_URL $CLIENT_WALLET

# Get specific order details (replace 0 with your order ID)
cast call $CALLBACK_ADDRESS 'getOrder(uint256)' \
  --rpc-url $SEPOLIA_RPC_URL 0
```

### Step 6: Test Order Execution

Trigger the order by manipulating the pair price:

```bash
# Transfer tokens to pair to change the ratio
cast send $TOKEN2 'transfer(address,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $PAIR_ADDRESS 20000000000000000000

# Execute swap to change the exchange rate
cast send $PAIR_ADDRESS 'swap(uint,uint,address,bytes)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  5000000000000000000 0 $CLIENT_WALLET "0x"
```

The RSC will detect the price change and automatically execute your stop order if the threshold is met.

## Order Management Commands

### Pause an Order
```bash
cast send $CALLBACK_ADDRESS 'pauseStopOrder(uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY 0
```

### Resume an Order
```bash
cast send $CALLBACK_ADDRESS 'resumeStopOrder(uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY 0
```

### Cancel an Order
```bash
cast send $CALLBACK_ADDRESS 'cancelStopOrder(uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY 0
```

### Force Execute an Order (Manual Override)
```bash
cast send $CALLBACK_ADDRESS 'executeStopOrder(address,uint256)' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  $CLIENT_WALLET 0
```

## Monitoring and Debugging

### Monitor Events

Track order creation events:
```bash
cast logs $CALLBACK_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --from-block 0 \
  --to-block latest \
  "StopOrderCreated(address,uint256,address,bool,address,address,uint256,uint256,uint256)"
```

Monitor order executions:
```bash
cast logs $CALLBACK_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --from-block 0 \
  --to-block latest \
  "StopOrderExecuted(address,uint256,address,address,address,uint256,uint256)"
```

Check for execution failures:
```bash
cast logs $CALLBACK_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --from-block 0 \
  --to-block latest \
  "ExecutionFailed(uint256,string)"
```

### Monitor RSC Activity

Track RSC order tracking:
```bash
cast logs $RSC_ADDRESS \
  --rpc-url $REACTIVE_RPC_URL \
  --from-block 0 \
  --to-block latest \
  "OrderTracked(address,uint256,address)"
```

Monitor pair subscriptions:
```bash
cast logs $RSC_ADDRESS \
  --rpc-url $REACTIVE_RPC_URL \
  --from-block 0 \
  --to-block latest \
  "PairSubscribed(address)"
```

### Check Current Status

Get current price for a pair:
```bash
cast call $CALLBACK_ADDRESS 'getCurrentPrice(address,bool)(uint256)' \
  --rpc-url $SEPOLIA_RPC_URL $PAIR_ADDRESS true
```

Check if pair is being monitored:
```bash
cast call $RSC_ADDRESS 'isPairSubscribed(address)(bool)' \
  --rpc-url $REACTIVE_RPC_URL $PAIR_ADDRESS
```

Get tracked order details:
```bash
cast call $RSC_ADDRESS 'getTrackedOrder(uint256)' \
  --rpc-url $REACTIVE_RPC_URL 0
```

## Advanced Configuration

### Adjusting Price Calculation

The price calculation uses the formula:
```
For selling token0: (reserve1 * coefficient) / reserve0 <= threshold
For selling token1: (reserve0 * coefficient) / reserve1 <= threshold
```

Example configurations:
- **10% drop**: coefficient=1000, threshold=900
- **20% drop**: coefficient=100, threshold=80
- **5% drop**: coefficient=10000, threshold=9500

### Gas Optimization Tips

1. **Batch Operations**: Create multiple orders in a single transaction if possible
2. **Optimal Amounts**: Use significant amounts to justify gas costs
3. **Pair Selection**: Choose liquid pairs to ensure execution success
4. **Cooldown Periods**: Default 5-minute cooldown prevents excessive gas usage

### Production Considerations

For production deployment, consider:

1. **Access Control**: Implement proper admin controls
2. **Fee Structure**: Add protocol fees for sustainability
3. **Slippage Protection**: Implement maximum slippage settings
4. **Oracle Integration**: Use price oracles for additional validation
5. **MEV Protection**: Consider MEV-resistant execution strategies

## Troubleshooting

### Common Issues

1. **Order Not Executing**:
   - Check if threshold is set correctly
   - Verify sufficient balance and allowances
   - Ensure pair has sufficient liquidity

2. **RSC Not Responding**:
   - Verify RSC has sufficient funding
   - Check event topics match contract events
   - Ensure proper network configuration

3. **Transaction Failures**:
   - Check gas limits are sufficient
   - Verify router approvals
   - Ensure tokens are tradeable

### Recovery Commands

Emergency ETH withdrawal from contracts:
```bash
# Withdraw from callback contract
cast send $CALLBACK_ADDRESS 'withdrawETH()' \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

## Support and Development

### Testing Framework

The system includes comprehensive tests:
```bash
# Run unit tests
forge test

# Run integration tests
forge test --fork-url $SEPOLIA_RPC_URL

# Run specific test
forge test --match-test testCreateStopOrder
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

### Support

For support and questions:
- Create an issue on GitHub
- Join our Discord community
- Check the documentation wiki

This stop order system represents a significant advancement in DeFi automation, providing users with sophisticated trading tools while maintaining security and decentralization.