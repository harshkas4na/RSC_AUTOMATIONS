// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

import '../lib/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '../lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import '../lib/reactive-lib/src/abstract-base/AbstractCallback.sol';

struct Reserves {
    uint112 reserve0;
    uint112 reserve1;
}

contract UniswapDemoStopOrderCallback is AbstractCallback {
    event Stop(
        address indexed pair,
        address indexed client,
        address indexed token,
        uint256[] tokens,
        uint256 orderId
    );
    
    event StopOrderFailed(
        address indexed pair,
        address indexed client,
        string reason
    );

    IUniswapV2Router02 private router;
    uint private constant DEADLINE = 2707391655;

    // Emergency controls
    bool public paused = false;
    address public owner;
    
    // Fee structure (optional)
    uint256 public feePercentage = 0; // 0.1% = 10, 1% = 100
    address public feeRecipient;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    constructor(
        address _callback_sender, 
        address _router
    ) AbstractCallback(_callback_sender) payable {
        router = IUniswapV2Router02(_router);
        owner = msg.sender;
    }

    function stop(
        address /* sender */,
        address pair,
        address client,
        bool isToken0,
        uint256 coefficient,
        uint256 threshold
    ) external authorizedSenderOnly whenNotPaused {
        try this.executeStopOrder(pair, client, isToken0, coefficient, threshold) {
            // Stop order executed successfully
        } catch Error(string memory reason) {
            emit StopOrderFailed(pair, client, reason);
        } catch {
            emit StopOrderFailed(pair, client, "Unknown error");
        }
    }

    function executeStopOrder(
        address pair,
        address client,
        bool isToken0,
        uint256 coefficient,
        uint256 threshold
    ) external {
        require(msg.sender == address(this), "Internal only");
        
        // Get pair tokens
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        
        // Verify threshold condition
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        require(
            belowThreshold(isToken0, Reserves({ reserve0: reserve0, reserve1: reserve1 }), coefficient, threshold), 
            'Rate above threshold'
        );
        
        // Determine tokens to sell and buy
        address tokenSell = isToken0 ? token0 : token1;
        address tokenBuy = isToken0 ? token1 : token0;
        
        // Check allowance and balance
        uint256 allowance = IERC20(tokenSell).allowance(client, address(this));
        require(allowance > 0, 'No allowance');
        require(IERC20(tokenSell).balanceOf(client) >= allowance, 'Insufficient funds');
        
        // Transfer tokens from client
        require(IERC20(tokenSell).transferFrom(client, address(this), allowance), "Transfer failed");
        
        // Calculate fee if applicable
        uint256 swapAmount = allowance;
        uint256 feeAmount = 0;
        
        if (feePercentage > 0) {
            feeAmount = (allowance * feePercentage) / 10000;
            swapAmount = allowance - feeAmount;
            
            if (feeAmount > 0) {
                require(IERC20(tokenSell).transfer(feeRecipient, feeAmount), "Fee transfer failed");
            }
        }
        
        // Approve router to spend tokens
        require(IERC20(tokenSell).approve(address(router), swapAmount), "Approval failed");
        
        // Setup swap path
        address[] memory path = new address[](2);
        path[0] = tokenSell;
        path[1] = tokenBuy;
        
        // Execute swap
        uint256[] memory amounts = router.swapExactTokensForTokens(
            swapAmount,
            0, // Accept any amount of tokens out
            path,
            address(this),
            DEADLINE
        );
        
        // Transfer swapped tokens back to client
        require(IERC20(tokenBuy).transfer(client, amounts[1]), "Token transfer failed");
        
        // Generate a pseudo order ID for tracking (in a real implementation, this should come from the reactive contract)
        uint256 orderId = uint256(keccak256(abi.encodePacked(pair, client, block.timestamp)));
        
        emit Stop(pair, client, tokenSell, amounts, orderId);
    }

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

    // Emergency token recovery
    function emergencyTokenRecovery(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner, amount), "Recovery failed");
    }

    // Function to withdraw ETH (if any)
    function withdrawETH(uint256 amount) external onlyOwner {
    require(amount > 0, "Amount must be greater than 0");
    require(amount <= address(this).balance, "Insufficient contract balance");
    
    payable(owner).transfer(amount);
}

// Optional: Keep the old function that withdraws everything
function withdrawAllETH() external onlyOwner {
    require(address(this).balance > 0, "No balance to withdraw");
    payable(owner).transfer(address(this).balance);
}

    // View functions
    function getRouterAddress() external view returns (address) {
        return address(router);
    }
}
