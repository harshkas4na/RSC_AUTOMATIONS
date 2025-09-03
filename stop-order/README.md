# Uniswap V2 Stop Order System with Reactive Smart Contracts

This project provides an automated stop order system for Uniswap V2 using Reactive Smart Contracts (RSC). The system allows users to create multiple stop orders within a single deployment that automatically execute token swaps when price thresholds are reached, without requiring manual intervention.

## How It Works - The Complete Flow

This system creates a seamless multi-order stop order experience:

1. **Initial Order Creation**:
   - First stop order is created during reactive contract deployment
   - Order includes token pair, client address, direction, and price threshold
   - System validates order parameters and emits creation event

2. **Additional Order Management**:
   - Contract deployer can create additional stop orders for any pair
   - Each order is tracked independently with unique order IDs
   - System supports multiple orders per pair and across different pairs

3. **Dynamic Event Monitoring**:
   - RSC contract automatically subscribes to relevant Uniswap V2 pair events
   - Monitors Sync events from all pairs with active orders
   - Optimized subscription management - only monitors pairs with active orders

4. **Automated Price Monitoring**:
   - RSC processes Sync events from Uniswap V2 pairs in real-time
   - Calculates current price ratios using reserve data
   - Compares against user-defined thresholds for each active order

5. **Smart Order Execution**:
   - When price conditions are met, RSC triggers callback to Sepolia
   - Callback contract validates conditions and executes swap via Uniswap router
   - Automatic cleanup of executed orders and subscription management

6. **Comprehensive Order Lifecycle**:
   - Orders can be cancelled by the contract deployer
   - System tracks order status (Active, Executed, Cancelled, Failed)
   - Dynamic unsubscription when no orders remain for a pair

## Contract Architecture

The system consists of two main contracts:

### 1. UniswapDemoStopOrderCallback (Sepolia Chain)
- **Order Execution**: Handles actual token swaps through Uniswap router
- **Validation Logic**: Checks price thresholds, balance, and allowances
- **Event Emission**: Emits `Stop` events for RSC to track execution status
- **Safety Features**: Comprehensive validation and error handling

### 2. UniswapDemoStopOrderReactive (Reactive Network)
- **Multi-Order Management**: Tracks multiple orders with unique IDs
- **Dynamic Subscriptions**: Subscribes to pairs with active orders only
- **Price Monitoring**: Processes Uniswap Sync events for price changes
- **Access Control**: Only deployer can create and cancel orders
- **Event Handling**: Processes both Sync and Stop events

## Key Features

### Advanced Multi-Order Management
- **Single Contract Deployment**: Handle unlimited orders from one RSC deployment
- **Cross-Pair Support**: Create orders for any Uniswap V2 pair
- **Independent Execution**: Each order executes independently based on its threshold
- **Order Lifecycle Tracking**: Complete status management (Active/Executed/Cancelled/Failed)

### Robust Execution Engine
- **Automatic Execution**: Orders execute when price thresholds are met
- **Balance Protection**: Real-time balance and allowance verification
- **Slippage Handling**: Configurable slippage protection
- **Gas Optimization**: Efficient event processing and subscription management

### Dynamic Resource Management
- **Smart Subscriptions**: Only monitor pairs with active orders
- **Automatic Cleanup**: Unsubscribe when no orders remain for a pair
- **Memory Efficiency**: Optimized data structures for gas efficiency
- **Event Filtering**: Process only relevant Sync and Stop events

### Access Control & Security
- **Deployer-Only Management**: Only contract deployer can create/cancel orders
- **Input Validation**: Comprehensive validation of all parameters
- **Safe Token Handling**: Proper allowance and balance checks
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
# Private keys (NEVER share or commit these)
export SEPOLIA_PRIVATE_KEY=your_sepolia_private_key
export REACTIVE_PRIVATE_KEY=your_reactive_private_key

# Network RPC URLs
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Contract addresses
export UNISWAP_V2_FACTORY=0x7E0987E5b3a30e3f2828572Bb659A548460a3003
export UNISWAP_V2_ROUTER=0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
export SEPOLIA_CALLBACK_PROXY_ADDR=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
export SYSTEM_CONTRACT_ADDR=reactive_system_contract_address

# Wallet addresses
export USER_WALLET=$(cast wallet address --private-key $SEPOLIA_PRIVATE_KEY)
export USER_WALLET_REACTIVE=$(cast wallet address --private-key $REACTIVE_PRIVATE_KEY)
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

### Step 1: Deploy Test Tokens (Optional)

Create test tokens for development and testing:

```bash
# Deploy test tokens
forge create --broadcast --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  src/UniswapDemoToken.sol:UniswapDemoToken \
  --constructor-args "Test Token A" "TKA"

export TOKEN_A=0x...  # Save deployed address

forge create --broadcast --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  src/UniswapDemoToken.sol:UniswapDemoToken \
  --constructor-args "Test Token B" "TKB"

export TOKEN_B=0x...  # Save deployed address
```

### Step 2: Create Uniswap Pair

```bash
# Create trading pair
cast send $UNISWAP_V2_FACTORY 'createPair(address,address)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $TOKEN_A $TOKEN_B

# Get pair address
PAIR_RAW=$(cast call $UNISWAP_V2_FACTORY 'getPair(address,address)' \
  --rpc-url $SEPOLIA_RPC $TOKEN_A $TOKEN_B)
export PAIR_ADDRESS=$(cast --to-checksum-address ${PAIR_RAW:26})

echo "Pair Address: $PAIR_ADDRESS"
```

### Step 3: Add Initial Liquidity

```bash
# Approve tokens for router
cast send $TOKEN_A 'approve(address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $UNISWAP_V2_ROUTER 50000000000000000000

cast send $TOKEN_B 'approve(address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $UNISWAP_V2_ROUTER 50000000000000000000

# Add liquidity (1:1 ratio)
cast send $UNISWAP_V2_ROUTER \
  'addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $TOKEN_A $TOKEN_B 20000000000000000000 20000000000000000000 0 0 $USER_WALLET 2707391655
```

### Step 4: Deploy Callback Contract (Sepolia)

```bash
# Deploy callback contract
forge create --broadcast --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  --via-ir src/UniswapDemoStopOrderCallback.sol:UniswapDemoStopOrderCallback \
  --value 0.01ether \
  --constructor-args $SEPOLIA_CALLBACK_PROXY_ADDR $UNISWAP_V2_ROUTER

export CALLBACK_ADDR=0x...  # Save deployed address
```

### Step 5: Deploy Reactive Contract with Initial Order

```bash
# Deploy reactive contract with first stop order
# Parameters: pair, callback, client, token0, coefficient, threshold
forge create --broadcast --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  --via-ir src/UniswapDemoStopOrderReactive.sol:UniswapDemoStopOrderReactive \
  --value 1ether \
  --constructor-args $PAIR_ADDRESS $CALLBACK_ADDR $USER_WALLET_REACTIVE true 1000000000000000000 950000000000000000

export REACTIVE_ADDR=0x...  # Save deployed address
```

The constructor parameters explained:
- `pair`: The Uniswap V2 pair address
- `callback`: The callback contract address on Sepolia  
- `client`: The address that will own the order (holds tokens)
- `token0`: `true` to sell token0, `false` to sell token1
- `coefficient`: Price calculation coefficient (e.g., 1000000000000000000 = 1e18)
- `threshold`: Price threshold that triggers the order (e.g., 950000000000000000 = 0.95 = 95%)

## Using the Stop Order System

### Step 1: Approve Token Spending

Approve the callback contract to spend your tokens:

```bash
# Approve token spending for initial order
cast send $TOKEN_A 'approve(address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $CALLBACK_ADDR 10000000000000000000  # 10 tokens
```

### Step 2: Create Additional Stop Orders

Only the contract deployer can create additional orders:

```bash
# Create second order for same pair with different threshold
cast send $REACTIVE_ADDR 'createStopOrder(address,address,bool,uint256,uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  $PAIR_ADDRESS $USER_WALLET_REACTIVE true 1000000000000000000 900000000000000000

# Create order for different pair
cast send $REACTIVE_ADDR 'createStopOrder(address,address,bool,uint256,uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  $OTHER_PAIR_ADDRESS $USER_WALLET_REACTIVE false 1000000000000000000 950000000000000000
```

### Step 3: Monitor Your Orders

Check order status:

```bash
# Get all active orders for user
cast call $REACTIVE_ADDR 'getUserActiveOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE

# Get specific order details
cast call $REACTIVE_ADDR 'getStopOrder(uint256)' \
  --rpc-url $REACTIVE_RPC 1

# Get all order categories for user
cast call $REACTIVE_ADDR 'getAllUserOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE

# Check next order ID
cast call $REACTIVE_ADDR 'nextOrderId()' \
  --rpc-url $REACTIVE_RPC
```

### Step 4: Test Order Execution

Trigger orders by changing pair prices:

```bash
# Make a large swap to change the price ratio
cast send $TOKEN_A 'approve(address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  $UNISWAP_V2_ROUTER 5000000000000000000

cast send $UNISWAP_V2_ROUTER \
  'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY \
  5000000000000000000 0 [$TOKEN_A,$TOKEN_B] $USER_WALLET 2707391655
```

The RSC will automatically detect the price change and execute any orders whose thresholds are met.

## Order Management Commands

### Cancel an Order
Only the contract deployer can cancel orders:

```bash
cast send $REACTIVE_ADDR 'cancelStopOrder(uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY 1
```

### Check Order Categories

```bash
# Active orders
cast call $REACTIVE_ADDR 'getUserActiveOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE

# Executed orders  
cast call $REACTIVE_ADDR 'getUserExecutedOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE

# Cancelled orders
cast call $REACTIVE_ADDR 'getUserCancelledOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE

# Failed orders
cast call $REACTIVE_ADDR 'getUserFailedOrders(address)' \
  --rpc-url $REACTIVE_RPC $USER_WALLET_REACTIVE
```

## Monitoring and Debugging

### Monitor Events

Track order creation:
```bash
cast logs $REACTIVE_ADDR \
  --rpc-url $REACTIVE_RPC \
  --from-block 0 \
  --to-block latest \
  "StopOrderCreated(uint256,address,address,bool,uint256,uint256)"
```

Monitor order executions:
```bash
cast logs $CALLBACK_ADDR \
  --rpc-url $SEPOLIA_RPC \
  --from-block 0 \
  --to-block latest \
  "Stop(address,address,address,uint256,uint256[])"
```

Monitor order completions:
```bash
cast logs $REACTIVE_ADDR \
  --rpc-url $REACTIVE_RPC \
  --from-block 0 \
  --to-block latest \
  "OrderCompleted(uint256)"
```

### Monitor Pair Reserves

Check current pair state:
```bash
cast call $PAIR_ADDRESS 'getReserves()' \
  --rpc-url $SEPOLIA_RPC
```

### Check Deployer Access

Verify deployer permissions:
```bash
cast call $REACTIVE_ADDR 'getDeployer()' \
  --rpc-url $REACTIVE_RPC

# Compare with your wallet
echo "Your wallet: $(cast wallet address --private-key $REACTIVE_PRIVATE_KEY)"
```

## Advanced Configuration

### Price Calculation

The system uses this formula to determine when orders trigger:
```
For selling token0: (reserve1 * coefficient) / reserve0 <= threshold
For selling token1: (reserve0 * coefficient) / reserve1 <= threshold
```

Example threshold configurations:
- **5% drop**: coefficient=1000000000000000000 (1e18), threshold=950000000000000000 (0.95e18)
- **10% drop**: coefficient=1000000000000000000 (1e18), threshold=900000000000000000 (0.90e18)
- **20% drop**: coefficient=1000000000000000000 (1e18), threshold=800000000000000000 (0.80e18)

### Multi-Order Strategy Examples

```bash
# Laddered sells: Multiple orders at different thresholds
# Order 1: Sell 25% at 5% drop
cast send $REACTIVE_ADDR 'createStopOrder(address,address,bool,uint256,uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  $PAIR_ADDRESS $USER_WALLET_REACTIVE true 1000000000000000000 950000000000000000

# Order 2: Sell 25% at 10% drop  
cast send $REACTIVE_ADDR 'createStopOrder(address,address,bool,uint256,uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  $PAIR_ADDRESS $USER_WALLET_REACTIVE true 1000000000000000000 900000000000000000

# Order 3: Sell remaining 50% at 20% drop
cast send $REACTIVE_ADDR 'createStopOrder(address,address,bool,uint256,uint256)' \
  --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  $PAIR_ADDRESS $USER_WALLET_REACTIVE true 1000000000000000000 800000000000000000
```

## Comprehensive Testing

### Test Multiple Pairs and Orders

For comprehensive testing, follow the multi-position testing guide that demonstrates:

1. **3 Trading Pairs**: TOKEN_A/TOKEN_B, TOKEN_C/TOKEN_B, TOKEN_D/TOKEN_B
2. **4 Stop Orders**: 2 orders on Pair 1, 1 order each on Pairs 2 and 3
3. **All Operations**: Create, execute, and cancel orders
4. **Subscription Management**: Verify proper cleanup when orders complete

### Validation Checks

```bash
# Verify all orders execute correctly
# Verify subscription cleanup
# Verify access control works
# Verify token balances change appropriately
# Verify pair reserves reflect executed swaps
```

## Production Considerations

For production deployment, consider:

1. **Access Control**: Implement proper governance or multisig controls
2. **Fee Structure**: Add protocol fees for sustainability  
3. **Slippage Protection**: Implement minimum output amount requirements
4. **Oracle Integration**: Use price oracles for additional validation
5. **MEV Protection**: Consider MEV-resistant execution strategies
6. **Gas Optimization**: Optimize for lower gas costs on both chains

## Troubleshooting

### Common Issues

1. **Order Not Executing**:
   - Check if threshold is set correctly relative to coefficient
   - Verify sufficient token balance and allowances
   - Ensure pair has adequate liquidity

2. **Access Control Errors**:
   - Verify you're using the correct deployer private key
   - Check that `getDeployer()` matches your wallet address

3. **Transaction Failures**:
   - Check gas limits are sufficient
   - Verify router approvals are in place
   - Ensure tokens are tradeable and not paused

### Recovery Commands

```bash
# Check deployer status
cast call $REACTIVE_ADDR 'getDeployer()' --rpc-url $REACTIVE_RPC

# Emergency withdrawal (if implemented)
cast send $CALLBACK_ADDR 'withdrawETH()' \
  --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY
```

## Support and Development

### Testing Framework

The system includes comprehensive tests:
```bash
# Run all tests
forge test

# Run with forking
forge test --fork-url $SEPOLIA_RPC

# Run specific test
forge test --match-test testMultipleOrders
```

### Contributing

1. Fork the repository
2. Create a feature branch  
3. Add comprehensive tests
4. Ensure all tests pass
5. Submit a pull request

### Support

For support and questions:
- Create an issue on GitHub
- Join our Discord community
- Check the documentation wiki

This multi-order stop order system enables sophisticated automated trading strategies while maintaining security, decentralization, and efficient resource usage. The single deployment approach with multi-order support makes it cost-effective for users who want to implement complex trading strategies across multiple pairs and thresholds.