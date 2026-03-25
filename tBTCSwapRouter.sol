// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
}

contract tBTCSwapRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    
    enum DEXVersion { V2, V3 }
    
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        address recipient;
        uint256 deadline;
        DEXVersion dexVersion;
        uint24 feeTier;
    }
    
    IUniswapV2Router public uniswapV2Router;
    
    uint256 public constant MAX_SLIPPAGE_BASIS_POINTS = 1000;
    uint256 public defaultSlippage = 50;
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        DEXVersion dexVersion
    );

    constructor(address _v2Router) {
        uniswapV2Router = IUniswapV2Router(_v2Router);
    }
    
    function swapExactTokensForTokens(SwapParams calldata params) 
        external 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= params.deadline, "Expired");
        require(params.amountIn > 0, "Zero amount");
        
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenIn).safeApprove(address(uniswapV2Router), params.amountIn);
        
        address[] memory path = new address[](2);
        path[0] = params.tokenIn;
        path[1] = params.tokenOut;
        
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            params.amountIn,
            params.amountOutMin,
            path,
            params.recipient,
            params.deadline
        );
        
        amountOut = amounts[amounts.length - 1];
        require(amountOut >= params.amountOutMin, "Slippage exceeded");
        
        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            params.dexVersion
        );
    }
    
    function getExpectedOutput(address tokenIn, address tokenOut, uint256 amountIn) 
        external 
        view 
        returns (uint256) 
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        uint[] memory amounts = uniswapV2Router.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
