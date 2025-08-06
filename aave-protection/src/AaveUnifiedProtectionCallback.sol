// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import '../lib/reactive-lib/src/abstract-base/AbstractCallback.sol';
import '../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

interface IERC20Detailed is IERC20 {
    function decimals() external view returns (uint8);
}

interface ILendingPool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    
    function repay(
        address asset,
        uint256 amount,
        uint256 rateMode,
        address onBehalfOf
    ) external returns (uint256);
    
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

interface IProtocolDataProvider {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
    
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

// NEW: Aave's native oracle interface
interface IPriceOracleGetter {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
    function getSourceOfAsset(address asset) external view returns (address);
    function getFallbackOracle() external view returns (address);
}

// NEW: Interface to get the price oracle from Aave's address provider
interface ILendingPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}

contract AaveUnifiedProtectionCallback is AbstractCallback {

    enum ProtectionType {
        COLLATERAL_DEPOSIT,
        DEBT_REPAYMENT,
        BOTH
    }

    struct UserProtection {
        bool isActive;
        ProtectionType protectionType;
        uint256 healthFactorThreshold;
        uint256 targetHealthFactor;
        address collateralAsset;
        address debtAsset;
        bool preferDebtRepayment;
    }

    event UserSubscribed(
        address indexed user,
        ProtectionType protectionType,
        uint256 healthFactorThreshold,
        uint256 targetHealthFactor,
        address collateralAsset,
        address debtAsset
    );
    
    event UserUnsubscribed(address indexed user);
    
    event ProtectionExecuted(
        address indexed user,
        address indexed lendingPool,
        string protectionMethod,
        address asset,
        uint256 amount,
        uint256 newHealthFactor
    );
    
    event ProtectionFailed(
        address indexed user,
        address indexed lendingPool,
        string reason
    );
    
    event DebugCalculation(
        address indexed user,
        uint256 currentHF,
        uint256 targetHF,
        uint256 totalCollateralUSD,
        uint256 totalDebtUSD,
        string calculationType
    );

    event ProtectionCycleCompleted(
        uint256 timestamp,
        uint256 totalUsersChecked,
        uint256 protectionsExecuted
    );

    address private lendingPool;
    address private protocolDataProvider;
    address private addressesProvider; // NEW: Aave addresses provider
    mapping(address => UserProtection) private userProtections;
    address[] private activeUsers;
    
    uint256 private constant RATE_MODE_VARIABLE = 2;
    uint256 private constant MAX_UINT256 = type(uint256).max;

    constructor(
        address _callback_sender,
        address _lendingPool,
        address _protocolDataProvider,
        address _addressesProvider  // NEW: Only need addresses provider now
    ) AbstractCallback(_callback_sender) payable {
        lendingPool = _lendingPool;
        protocolDataProvider = _protocolDataProvider;
        addressesProvider = _addressesProvider;
    }

    function subscribeToProtection(
        ProtectionType _protectionType,
        uint256 _healthFactorThreshold,
        uint256 _targetHealthFactor,
        address _collateralAsset,
        address _debtAsset,
        bool _preferDebtRepayment
    ) external payable{
        require(_healthFactorThreshold > 0, "Invalid threshold");
        require(_targetHealthFactor > _healthFactorThreshold, "Target must be higher than threshold");
        
        // NEW: Validate that assets are supported by Aave (they have price oracles)
        require(_validateAssetSupported(_collateralAsset), "Collateral asset not supported by Aave");
        require(_validateAssetSupported(_debtAsset), "Debt asset not supported by Aave");

        UserProtection storage protection = userProtections[msg.sender];
        
        if (!protection.isActive) {
            activeUsers.push(msg.sender);
        }

        protection.isActive = true;
        protection.protectionType = _protectionType;
        protection.healthFactorThreshold = _healthFactorThreshold;
        protection.targetHealthFactor = _targetHealthFactor;
        protection.collateralAsset = _collateralAsset;
        protection.debtAsset = _debtAsset;
        protection.preferDebtRepayment = _preferDebtRepayment;

        emit UserSubscribed(
            msg.sender,
            _protectionType,
            _healthFactorThreshold,
            _targetHealthFactor,
            _collateralAsset,
            _debtAsset
        );
    }

    function unsubscribeFromProtection() external {
        UserProtection storage protection = userProtections[msg.sender];
        require(protection.isActive, "Not subscribed");

        protection.isActive = false;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            if (activeUsers[i] == msg.sender) {
                activeUsers[i] = activeUsers[activeUsers.length - 1];
                activeUsers.pop();
                break;
            }
        }

        emit UserUnsubscribed(msg.sender);
    }

    function checkAndProtectPositions(
        address /* sender */
    ) external authorizedSenderOnly {
        uint256 totalUsersChecked = 0;
        uint256 protectionsExecuted = 0;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address user = activeUsers[i];
            UserProtection memory protection = userProtections[user];
            
            if (!protection.isActive) continue;
            
            totalUsersChecked++;

            try this._checkAndProtectUser(user, protection) returns (bool wasProtected) {
                if (wasProtected) {
                    protectionsExecuted++;
                }
            } catch {
                emit ProtectionFailed(user, lendingPool, "Unexpected error during protection check");
            }
        }
        
        emit ProtectionCycleCompleted(
            block.timestamp,
            totalUsersChecked,
            protectionsExecuted
        );
    }

    function _checkAndProtectUser(address user, UserProtection memory protection) external returns (bool) {
        require(msg.sender == address(this), "Internal function");
        
        (,,,,, uint256 currentHealthFactor) = ILendingPool(lendingPool).getUserAccountData(user);
        
        if (currentHealthFactor >= protection.healthFactorThreshold) {
            return false;
        }

        bool protectionExecuted = false;

        if (protection.protectionType == ProtectionType.COLLATERAL_DEPOSIT) {
            protectionExecuted = _executeCollateralProtection(user, protection, currentHealthFactor);
        } else if (protection.protectionType == ProtectionType.DEBT_REPAYMENT) {
            protectionExecuted = _executeDebtRepayment(user, protection, currentHealthFactor);
        } else if (protection.protectionType == ProtectionType.BOTH) {
            if (protection.preferDebtRepayment) {
                protectionExecuted = _executeDebtRepayment(user, protection, currentHealthFactor);
                if (!protectionExecuted) {
                    protectionExecuted = _executeCollateralProtection(user, protection, currentHealthFactor);
                }
            } else {
                protectionExecuted = _executeCollateralProtection(user, protection, currentHealthFactor);
                if (!protectionExecuted) {
                    protectionExecuted = _executeDebtRepayment(user, protection, currentHealthFactor);
                }
            }
        }

        if (!protectionExecuted) {
            emit ProtectionFailed(user, lendingPool, "No protection method could be executed");
        }
        
        return protectionExecuted;
    }

    function _executeCollateralProtection(
        address user,
        UserProtection memory protection,
        uint256 currentHealthFactor
    ) internal returns (bool) {
        try this._performCollateralProtection(user, protection, currentHealthFactor) 
        returns (uint256 collateralAdded) {
            if (collateralAdded > 0) {
                (,,,,, uint256 finalHealthFactor) = ILendingPool(lendingPool).getUserAccountData(user);
                emit ProtectionExecuted(
                    user,
                    lendingPool,
                    "Collateral Deposit",
                    protection.collateralAsset,
                    collateralAdded,
                    finalHealthFactor
                );
                return true;
            }
            return false;
        } catch Error(string memory reason) {
            emit ProtectionFailed(user, lendingPool, string(abi.encodePacked("Collateral protection failed: ", reason)));
            return false;
        } catch {
            emit ProtectionFailed(user, lendingPool, "Collateral protection failed: Unknown error");
            return false;
        }
    }

    function _executeDebtRepayment(
        address user,
        UserProtection memory protection,
        uint256 currentHealthFactor
    ) internal returns (bool) {
        try this._performDebtRepayment(user, protection, currentHealthFactor) 
        returns (uint256 repaymentAmount) {
            if (repaymentAmount > 0) {
                (,,,,, uint256 finalHealthFactor) = ILendingPool(lendingPool).getUserAccountData(user);
                emit ProtectionExecuted(
                    user,
                    lendingPool,
                    "Debt Repayment",
                    protection.debtAsset,
                    repaymentAmount,
                    finalHealthFactor
                );
                return true;
            }
            return false;
        } catch Error(string memory reason) {
            emit ProtectionFailed(user, lendingPool, string(abi.encodePacked("Debt repayment failed: ", reason)));
            return false;
        } catch {
            emit ProtectionFailed(user, lendingPool, "Debt repayment failed: Unknown error");
            return false;
        }
    }

    function _performCollateralProtection(
        address user,
        UserProtection memory protection,
        uint256 /*currentHealthFactor*/
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal function");
        
        (, uint256 totalDebtUSD,,,,) = ILendingPool(lendingPool).getUserAccountData(user);
        if (totalDebtUSD == 0) {
            return 0;
        }

        uint256 collateralNeeded = calculateCollateralNeeded(user, protection);
        
        if (collateralNeeded > 0) {
            uint256 userBalance = IERC20(protection.collateralAsset).balanceOf(user);
            require(userBalance >= collateralNeeded, "Insufficient user balance for collateral");
            
            uint256 approvedAmount = IERC20(protection.collateralAsset).allowance(user, address(this));
            require(approvedAmount >= collateralNeeded, "Insufficient approved collateral");
            
            IERC20(protection.collateralAsset).transferFrom(user, address(this), collateralNeeded);
            IERC20(protection.collateralAsset).approve(lendingPool, collateralNeeded);
            
            ILendingPool(lendingPool).supply(
                protection.collateralAsset,
                collateralNeeded,
                user,
                0
            );
        }
        
        return collateralNeeded;
    }

    function _performDebtRepayment(
        address user,
        UserProtection memory protection,
        uint256 /*currentHealthFactor*/
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal function");
        
        (,, uint256 currentVariableDebt,,,,,,) = IProtocolDataProvider(protocolDataProvider).getUserReserveData(protection.debtAsset, user);
        if (currentVariableDebt == 0) {
            return 0;
        }
        
        uint256 repaymentAmount = calculateRepaymentAmount(user, protection);
        
        if (repaymentAmount > 0) {
            uint256 userBalance = IERC20(protection.debtAsset).balanceOf(user);
            require(userBalance >= repaymentAmount, "Insufficient user balance for repayment");
            
            uint256 approvedAmount = IERC20(protection.debtAsset).allowance(user, address(this));
            require(approvedAmount >= repaymentAmount, "Insufficient approved debt asset");
            
            IERC20(protection.debtAsset).transferFrom(user, address(this), repaymentAmount);
            IERC20(protection.debtAsset).approve(lendingPool, repaymentAmount);
            
            ILendingPool(lendingPool).repay(
                protection.debtAsset,
                repaymentAmount,
                RATE_MODE_VARIABLE,
                user
            );
        }
        
        return repaymentAmount;
    }

    // NEW: Updated calculation functions using Aave's oracle
    function calculateCollateralNeeded(
        address user,
        UserProtection memory protection
    ) internal view returns (uint256) {
        (uint256 totalCollateralUSD, uint256 totalDebtUSD, , uint256 currentLiquidationThreshold, , uint256 currentHealthFactor) = 
            ILendingPool(lendingPool).getUserAccountData(user);
        
        if (totalDebtUSD == 0 || currentHealthFactor >= protection.targetHealthFactor) {
            return 0;
        }
        
        uint256 collateralLiquidationThreshold = getAssetLiquidationThreshold(protection.collateralAsset);
        uint256 currentWeightedCollateral = (totalCollateralUSD * currentLiquidationThreshold) / 10000;
        uint256 targetHF_BasisPoints = protection.targetHealthFactor / 1e14;
        uint256 requiredWeightedCollateral = (targetHF_BasisPoints * totalDebtUSD) / 10000;
        
        if (requiredWeightedCollateral <= currentWeightedCollateral) {
            return 0;
        }
        
        uint256 additionalWeightedCollateral = requiredWeightedCollateral - currentWeightedCollateral;
        uint256 additionalCollateralUSD = (additionalWeightedCollateral * 10000) / collateralLiquidationThreshold;
        
        // NEW: Use Aave's oracle instead of Chainlink
        uint256 collateralPriceUSD = _getAssetPrice(protection.collateralAsset);
        require(collateralPriceUSD > 0, "Invalid collateral price from Aave oracle");
        
        uint256 collateralNeeded = (additionalCollateralUSD * 1e18) / collateralPriceUSD;
        
        return collateralNeeded;
    }

    function calculateRepaymentAmount(
        address user,
        UserProtection memory protection
    ) internal view returns (uint256) {
        (uint256 totalCollateralUSD, uint256 totalDebtUSD, , uint256 currentLiquidationThreshold, , uint256 currentHealthFactor) = 
            ILendingPool(lendingPool).getUserAccountData(user);
        
        if (totalDebtUSD == 0 || currentHealthFactor >= protection.targetHealthFactor) {
            return 0;
        }
        
        uint256 weightedCollateral = (totalCollateralUSD * currentLiquidationThreshold) / 10000;
        uint256 targetDebtUSD = (weightedCollateral * 10000) / (protection.targetHealthFactor / 1e14);
        
        if (totalDebtUSD <= targetDebtUSD) {
            return 0;
        }
        
        (,, uint256 currentVariableDebt,,,,,,) = IProtocolDataProvider(protocolDataProvider).getUserReserveData(protection.debtAsset, user);
        if (currentVariableDebt == 0) {
            return 0;
        }
        
        uint256 debtToRepayUSD = totalDebtUSD - targetDebtUSD;
        
        // NEW: Use Aave's oracle instead of Chainlink
        uint256 debtAssetPriceUSD = _getAssetPrice(protection.debtAsset);
        require(debtAssetPriceUSD > 0, "Invalid debt asset price from Aave oracle");
        
        uint8 decimals = IERC20Detailed(protection.debtAsset).decimals();
        uint256 assetDebtUSD = (debtAssetPriceUSD * currentVariableDebt) / (10 ** decimals);
        
        uint256 tokensToRepay;
        if (assetDebtUSD <= debtToRepayUSD) {
            tokensToRepay = currentVariableDebt;
        } else {
            tokensToRepay = (debtToRepayUSD * currentVariableDebt) / assetDebtUSD;
        }
        
        if (tokensToRepay > currentVariableDebt) {
            tokensToRepay = currentVariableDebt;
        }
        
        return tokensToRepay;
    }

    function getAssetLiquidationThreshold(address asset) internal view returns (uint256) {
        (,, uint256 liquidationThreshold,,,,,,,) = IProtocolDataProvider(protocolDataProvider)
            .getReserveConfigurationData(asset);
        return liquidationThreshold;
    }

    // NEW: Helper function to get asset price from Aave's oracle
    function _getAssetPrice(address asset) internal view returns (uint256) {
        address priceOracleAddress = ILendingPoolAddressesProvider(addressesProvider).getPriceOracle();
        return IPriceOracleGetter(priceOracleAddress).getAssetPrice(asset);
    }

    // NEW: Helper function to validate that an asset is supported by Aave
    function _validateAssetSupported(address asset) internal view returns (bool) {
        try this.getAssetPrice(asset) returns (uint256 price) {
            return price > 0;
        } catch {
            return false;
        }
    }

    // NEW: Public function to get supported assets price (for testing/debugging)
    function getAssetPrice(address asset) external view returns (uint256) {
        return _getAssetPrice(asset);
    }

    // NEW: Function to get multiple asset prices at once
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        address priceOracleAddress = ILendingPoolAddressesProvider(addressesProvider).getPriceOracle();
        return IPriceOracleGetter(priceOracleAddress).getAssetsPrices(assets);
    }

    // View functions
    function getUserProtection(address user) external view returns (UserProtection memory) {
        return userProtections[user];
    }
    
    function getActiveUsersCount() external view returns (uint256) {
        return activeUsers.length;
    }
    
    function getActiveUser(uint256 index) external view returns (address) {
        require(index < activeUsers.length, "Index out of bounds");
        return activeUsers[index];
    }
    
    function isUserActive(address user) external view returns (bool) {
        return userProtections[user].isActive;
    }
}