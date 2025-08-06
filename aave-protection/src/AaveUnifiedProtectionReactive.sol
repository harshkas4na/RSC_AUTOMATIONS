// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "../lib/reactive-lib/src/interfaces/IReactive.sol";
import "../lib/reactive-lib/src/abstract-base/AbstractPausableReactive.sol";

contract AaveUnifiedProtectionReactive is IReactive, AbstractPausableReactive {

    event ProtectionCheckTriggered(uint256 timestamp, uint256 blockNumber);
    event ProtectionCompleted(uint256 timestamp);

    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 private constant PROTECTION_EXECUTED_TOPIC_0 = 0x8391e53f51e32cd6757d5247de7235b3bed7d5f0d8673b42a7e286daa9b1e954; // keccak256("ProtectionExecuted(address,address,string,address,uint256,uint256)")
    
    // NEW: Topic for the completion event that's always emitted
    uint256 private constant PROTECTION_CYCLE_COMPLETED_TOPIC_0 = 0xb2a1984478c1064cb30b6e5bd7410ed80e897a5a51f65a9c4a826d92ba5a3492; // keccak256("ProtectionCycleCompleted(uint256,uint256,uint256)")
    
    uint64 private constant CALLBACK_GAS_LIMIT = 2000000; // Higher gas limit for multiple user checks

    // State specific to ReactVM instance of the contract.
    // NOTE: This contract runs on Kopli (Reactive Network) and has NO access to Aave data on Sepolia
    // It only triggers callbacks - all Aave data reading happens in the callback contract on Sepolia
    address private protectionManager;
    uint256 public cronTopic;
    bool private processingActive;

    constructor(
        address _protectionManager,
        address _service,
        uint256 _cronTopic
    ) payable {
        service = ISystemContract(payable(_service));
        protectionManager = _protectionManager;
        cronTopic = _cronTopic;
        processingActive = false;
        
        if (!vm) {
            // Subscribe to CRON events for periodic monitoring
            service.subscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            // Subscribe to ProtectionCycleCompleted events from the callback contract
            // This event is ALWAYS emitted, ensuring the processing flag gets reset
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                protectionManager,
                PROTECTION_CYCLE_COMPLETED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory result = new Subscription[](1);
        result[0] = Subscription(
            block.chainid,
            address(service),
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        return result;
    }

    // Methods specific to ReactVM instance of the contract.
    // IMPORTANT: This contract runs on Kopli and cannot access Aave data on Sepolia
    // It only triggers protection checks - all data reading happens in callback contract
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic) {
            // CRON event - trigger protection check for all users
            // NOTE: We don't check health factors here because this contract
            // runs on Kopli and has no access to Aave data on Sepolia
            if (processingActive) {
                return; // Already processing, skip this cycle
            }
            
            // Simply trigger the callback - let Sepolia contract do all the Aave checks
            bytes memory payload = abi.encodeWithSignature(
                "checkAndProtectPositions(address)",
                address(0) // sender (not used in callback)
            );
            
            processingActive = true;
            
            emit ProtectionCheckTriggered(block.timestamp, block.number);
            emit Callback(
                SEPOLIA_CHAIN_ID,
                protectionManager,
                CALLBACK_GAS_LIMIT,
                payload
            );
            
        } else if (log._contract == protectionManager && log.topic_0 == PROTECTION_CYCLE_COMPLETED_TOPIC_0) {
            // ProtectionCycleCompleted event from callback contract on Sepolia
            // This event is ALWAYS emitted regardless of whether any protections were executed
            // This ensures the processing flag gets reset and the system continues working
            processingActive = false;
            emit ProtectionCompleted(block.timestamp);
        }
    }
    
    // View functions to check current state
    function isProcessingActive() external view returns (bool) {
        return processingActive;
    }
    
    function getProtectionManager() external view returns (address) {
        return protectionManager;
    }
    
    function getCronTopic() external view returns (uint256) {
        return cronTopic;
    }
    
    // Reset processing flag manually if needed (emergency function)
    function resetProcessingFlag() external {
        // In production, you might want to add access control here
        processingActive = false;
    }
}