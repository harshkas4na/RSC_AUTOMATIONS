# Aave Combined Liquidation Protection System

## Overview

The **Aave Combined Liquidation Protection System** implements a comprehensive reactive smart contract system that provides automated liquidation protection for multiple users through a single deployed contract. Users can subscribe to protection services that automatically monitor their Aave positions and execute protection strategies when health factors drop below defined thresholds.

The system supports three protection strategies:
- **Collateral Deposit**: Automatically supplies additional collateral to improve health factor
- **Debt Repayment**: Automatically repays debt to reduce leverage and improve health factor  
- **Combined Protection**: Uses both strategies with user-defined preference order

## Key Features

- **Multi-User Support**: Single contract deployment serves all users
- **Subscription-Based**: Users subscribe/unsubscribe without deploying contracts
- **Flexible Protection**: Choose between collateral deposit, debt repayment, or both
- **Universal Asset Support**: Works with ANY asset supported by Aave
- **Aave Native Oracle**: Uses Aave's built-in price oracle system
- **Automated Monitoring**: Periodic health factor checks via CRON events
- **Continuous Operation**: System never gets stuck in processing loops
- **Gas Efficient**: Batch processing of multiple users in single callback
- **Non-Custodial**: Users maintain control of their assets through approvals

## Architecture

**Reactive Contract (Kopli Network)**: Runs on the Reactive Network (Kopli) and subscribes to CRON events to trigger callbacks to the destination chain.

**Callback Contract (Sepolia)**: Runs on Sepolia where Aave is deployed. Handles all Aave interactions, user subscriptions, health factor monitoring, and protection execution.

## Deployment

### Environment Variables

```bash
export SEPOLIA_RPC=<your_sepolia_rpc_url>
export DESTINATION_PRIVATE_KEY=<your_private_key>
export REACTIVE_RPC=<reactive_network_rpc>
export REACTIVE_PRIVATE_KEY=<reactive_private_key>
export DESTINATION_CALLBACK_PROXY_ADDR=<callback_proxy_address>
export SYSTEM_CONTRACT_ADDR=<system_contract_address>
export CRON_TOPIC=0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70
```

### Aave Sepolia Addresses

```bash
export LENDING_POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
export PROTOCOL_DATA_PROVIDER=0x3e9708d80f7B3e43118013075F7e95CE3AB31F31
export ADDRESSES_PROVIDER=0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A
```

### Deploy Contracts

**1. Deploy Callback Contract (Sepolia)**
```bash
forge create --broadcast --rpc-url $SEPOLIA_RPC --private-key $DESTINATION_PRIVATE_KEY src/demos/aave-unified-protection/AaveUnifiedProtectionCallback.sol:AaveUnifiedProtectionCallback --value 0.01ether --constructor-args $DESTINATION_CALLBACK_PROXY_ADDR $LENDING_POOL $PROTOCOL_DATA_PROVIDER $ADDRESSES_PROVIDER
```

**2. Deploy Reactive Contract (Kopli)**
```bash
forge create --legacy --broadcast --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY src/demos/aave-unified-protection/AaveUnifiedProtectionReactive.sol:AaveUnifiedProtectionReactive --value 0.01ether --constructor-args $CALLBACK_ADDR $SYSTEM_CONTRACT_ADDR $CRON_TOPIC
```

## Supported Assets (Aave V3 Sepolia)

| Symbol | Address |
|--------|---------|
| **DAI** | `0xFF34B3d4Aee8ddCd6F9AfffB6Fe49bD371b8a357` |
| **LINK** | `0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5` |
| **USDC** | `0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8` |
| **WBTC** | `0x29f2D40B0605204364af54EC677bD022da425d03` |
| **WETH** | `0xC558DBdD856501FCd9aaF1E62eaE57A9F0629a3C` |
| **USDT** | `0xaA8E23Fb1079EA71e0a56f48a2aA51851D8433D0` |
| **AAVE** | `0x88541670E55cC00bEefd87EB59EDd1b7C511AC9A` |
| **EURS** | `0x6d906e526a4e2Ca02097BA9d0caA3c382f52278E` |
| **GHO** | `0xc4bF5CbDaBE595361438F8c6a187bDC330539c60` |

## Usage

### 1. Find Supported Assets

Get available assets from Aave:
```bash
cast call $PROTOCOL_DATA_PROVIDER "getAllReservesTokens()" --rpc-url $SEPOLIA_RPC
```

Test if asset is supported:
```bash
cast call $CALLBACK_ADDR "getAssetPrice(address)" --rpc-url $SEPOLIA_RPC <ASSET_ADDRESS>
```

### 2. Subscribe to Protection

**Approve Assets**
```bash
# Approve collateral asset
cast send <COLLATERAL_ASSET> 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>

# Approve debt asset (if using debt repayment)
cast send <DEBT_ASSET> 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>
```

**Subscribe**
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(uint8,uint256,uint256,address,address,bool)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY <PROTECTION_TYPE> <THRESHOLD> <TARGET> <COLLATERAL_ASSET> <DEBT_ASSET> <PREFER_DEBT_REPAYMENT>
```

**Protection Types:**
- `0` = Collateral Deposit Only
- `1` = Debt Repayment Only  
- `2` = Both Strategies

**Health Factor Format:**
- Threshold: `1200000000000000000` (1.2)
- Target: `1500000000000000000` (1.5)

### 3. Monitor System

**Check Subscription**
```bash
cast call $CALLBACK_ADDR "getUserProtection(address)" --rpc-url $SEPOLIA_RPC <USER_ADDRESS>
```

**View Active Users**
```bash
cast call $CALLBACK_ADDR "getActiveUsersCount()" --rpc-url $SEPOLIA_RPC
```

**Unsubscribe**
```bash
cast send $CALLBACK_ADDR "unsubscribeFromProtection()" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY
```

## Events

Monitor these events on Sepolia:
- `UserSubscribed`: User successfully subscribed
- `ProtectionExecuted`: Protection successfully executed
- `ProtectionFailed`: Protection attempt failed
- `ProtectionCycleCompleted`: Monitoring cycle completed

## Examples

### Collateral Protection Only
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(uint8,uint256,uint256,address,address,bool)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY 0 1200000000000000000 1500000000000000000 <COLLATERAL_ASSET> <DEBT_ASSET> false
```

### Debt Repayment Only
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(uint8,uint256,uint256,address,address,bool)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY 1 1200000000000000000 1500000000000000000 <COLLATERAL_ASSET> <DEBT_ASSET> false
```

### Combined Protection
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(uint8,uint256,uint256,address,address,bool)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY 2 1200000000000000000 1500000000000000000 <COLLATERAL_ASSET> <DEBT_ASSET> true
```

## Testing

### Create Test Position

**Supply Collateral**
```bash
cast send $LENDING_POOL 'supply(address,uint256,address,uint16)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY <ASSET> <AMOUNT> <USER_ADDRESS> 0
```

**Borrow**
```bash
cast send $LENDING_POOL 'borrow(address,uint256,uint256,uint16,address)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY <ASSET> <AMOUNT> 2 0 <USER_ADDRESS>
```

### Get Test Tokens

Visit [app.aave.com](https://app.aave.com) → Enable testnet mode → Use Faucet tab

## Troubleshooting

**Asset not supported**: Use `getAssetPrice()` to verify asset has oracle support

**Insufficient approvals**: Increase token approvals for protection assets

**Protection not triggering**: Check health factor is below threshold

**Contract reverts**: Verify contract deployed with correct Aave addresses

## Security Considerations

- Users maintain full control of assets through approval system
- System is non-custodial - no assets are held by contracts
- Oracle prices sourced directly from Aave's native oracle
- Protection only executes when health factor drops below threshold
- Batch processing optimizes gas costs

## System Requirements

- **Minimum Balance**: Users need sufficient balance of protection assets
- **Approvals**: Must approve contract to spend protection assets
- **Health Factor**: Position must be below threshold to trigger protection
- **Asset Support**: Assets must be supported by Aave protocol