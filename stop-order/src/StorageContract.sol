// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

// import '../lib/reactive-lib/src/abstract-base/AbstractCallback.sol';

struct UserContracts {
    address callbackContract;
    address rscContract;
    uint256 chainId;
}

contract StopOrderStorageCallback  {
    
    // Simple mapping: user address => their contracts
    mapping(address => UserContracts) public userContracts;
    
    event ContractStored(
        address indexed user,
        address callbackContract,
        address rscContract,
        uint256 chainId
    );

   

    // Called by RSC contracts to store user contract addresses
    function storeUserContracts(
        address user,
        address callbackContract,
        address rscContract,
        uint256 chainId
    ) external  {
        require(user != address(0), "Invalid user address");
        require(callbackContract != address(0), "Invalid callback contract");
        require(rscContract != address(0), "Invalid RSC contract");
        
        userContracts[user] = UserContracts({
            callbackContract: callbackContract,
            rscContract: rscContract,
            chainId: chainId
        });
        
        emit ContractStored(user, callbackContract, rscContract, chainId);
    }
    
    // View function to get user's contracts
    function getUserContracts(address user) external view returns (UserContracts memory) {
        return userContracts[user];
    }
    
    // Check if user has stored contracts
    function hasUserContracts(address user) external view returns (bool) {
        return userContracts[user].rscContract != address(0);
    }
}