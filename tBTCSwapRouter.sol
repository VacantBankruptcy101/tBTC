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

/**
 * @title tBTC Gasless Swap Router
 * @notice Users pay gas in tBTC testnet tokens, relayer pays ETH
 */
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
    
    struct GaslessSwapRequest {
        SwapParams params;
        uint256 tbtcGasPayment;
        uint256 nonce;
        bytes signature;
    }
    
    // FIXED: Moved visibility specifier before type name
    IUniswapV2Router public uniswapV2Router;
    
    IERC20 public tbtcToken;
    
    mapping(address => bool) public approvedRelayers;
    mapping(address => uint256) public userNonces;
    
    uint256 public relayerFeeBps = 50;
    
    event GaslessSwapExecuted(
        address indexed user,
        address indexed relayer,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 gasPayment
    );
    
    event StandardSwapExecuted(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address _v2Router,
        address _tbtcToken
    ) {
        uniswapV2Router = IUniswapV2Router(_v2Router);
        tbtcToken = IERC20(_tbtcToken);
        approvedRelayers[msg.sender] = true;
    }
    
    modifier onlyRelayer() {
        require(approvedRelayers[msg.sender], "Not approved relayer");
        _;
    }
    
    function swapExactTokensForTokens(SwapParams calldata params) 
        external 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= params.deadline, "Expired");
        
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
        
        emit StandardSwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut
        );
        
        return amountOut;
    }
    
    function executeGaslessSwap(GaslessSwapRequest calldata request) 
        external 
        onlyRelayer 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= request.params.deadline, "Expired");
        require(userNonces[request.params.recipient] == request.nonce, "Invalid nonce");
        
        require(verifyRequest(request), "Invalid signature");
        
        userNonces[request.params.recipient]++;
        
        require(
            tbtcToken.transferFrom(request.params.recipient, msg.sender, request.tbtcGasPayment),
            "Gas payment failed"
        );
        
        IERC20(request.params.tokenIn).safeTransferFrom(
            request.params.recipient, 
            address(this), 
            request.params.amountIn
        );
        
        IERC20(request.params.tokenIn).safeApprove(address(uniswapV2Router), request.params.amountIn);
        
        address[] memory path = new address[](2);
        path[0] = request.params.tokenIn;
        path[1] = request.params.tokenOut;
        
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            request.params.amountIn,
            request.params.amountOutMin,
            path,
            request.params.recipient,
            request.params.deadline
        );
        
        amountOut = amounts[amounts.length - 1];
        
        emit GaslessSwapExecuted(
            request.params.recipient,
            msg.sender,
            request.params.tokenIn,
            request.params.tokenOut,
            request.params.amountIn,
            amountOut,
            request.tbtcGasPayment
        );
        
        return amountOut;
    }
    
    function approveForGasless(uint256 tbtcAmount, uint256 tokenAmount, address token) 
        external 
    {
        tbtcToken.approve(address(this), tbtcAmount);
        IERC20(token).approve(address(this), tokenAmount);
    }
    
    function verifyRequest(GaslessSwapRequest calldata request) 
        internal 
        pure 
        returns (bool) 
    {
        return true;
    }
    
    function addRelayer(address relayer) external onlyOwner {
        approvedRelayers[relayer] = true;
    }
    
    function removeRelayer(address relayer) external onlyOwner {
        approvedRelayers[relayer] = false;
    }
    
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
    }
    
    struct GaslessSwapRequest {
        SwapParams params;
        uint256 tbtcGasPayment; // Amount of tBTC to pay for gas
        uint256 nonce;
        bytes signature;
    }
    
    IUniswapV2Router public uniswapV2Router;
    
    // The tBTC token used for gas payments
    IERC20 public tbtcToken;
    
    // Approved relayers who can execute gasless swaps
    mapping(address => bool) public approvedRelayers;
    mapping(address => uint256) public userNonces;
    
    uint256 public relayerFeeBps = 50; // 0.5% fee to relayer
    
    event GaslessSwapExecuted(
        address indexed user,
        address indexed relayer,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 gasPayment
    );
    
    event StandardSwapExecuted(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address _v2Router,
        address _tbtcToken
    ) {
        uniswapV2Router = IUniswapV2Router(_v2Router);
        tbtcToken = IERC20(_tbtcToken);
        approvedRelayers[msg.sender] = true;
    }
    
    modifier onlyRelayer() {
        require(approvedRelayers[msg.sender], "Not approved relayer");
        _;
    }
    
    /**
     * @notice STANDARD SWAP: User pays ETH gas themselves
     */
    function swapExactTokensForTokens(SwapParams calldata params) 
        external 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= params.deadline, "Expired");
        
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
        
        emit StandardSwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut
        );
        
        return amountOut;
    }
    
    /**
     * @notice GASLESS SWAP: Relayer pays ETH gas, user pays in tBTC
     * @param request Gasless swap request signed by user
     */
    function executeGaslessSwap(GaslessSwapRequest calldata request) 
        external 
        onlyRelayer 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= request.params.deadline, "Expired");
        require(userNonces[request.params.recipient] == request.nonce, "Invalid nonce");
        
        // Verify signature (simplified - implement full EIP-712)
        require(verifyRequest(request), "Invalid signature");
        
        userNonces[request.params.recipient]++;
        
        // Pull tBTC gas payment from user to relayer
        require(
            tbtcToken.transferFrom(request.params.recipient, msg.sender, request.tbtcGasPayment),
            "Gas payment failed"
        );
        
        // Also pull swap amount from user
        IERC20(request.params.tokenIn).safeTransferFrom(
            request.params.recipient, 
            address(this), 
            request.params.amountIn
        );
        
        // Approve and execute swap
        IERC20(request.params.tokenIn).safeApprove(address(uniswapV2Router), request.params.amountIn);
        
        address[] memory path = new address[](2);
        path[0] = request.params.tokenIn;
        path[1] = request.params.tokenOut;
        
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            request.params.amountIn,
            request.params.amountOutMin,
            path,
            request.params.recipient, // Output goes to user
            request.params.deadline
        );
        
        amountOut = amounts[amounts.length - 1];
        
        emit GaslessSwapExecuted(
            request.params.recipient,
            msg.sender,
            request.params.tokenIn,
            request.params.tokenOut,
            request.params.amountIn,
            amountOut,
            request.tbtcGasPayment
        );
        
        return amountOut;
    }
    
    /**
     * @notice User approves tokens for gasless operation
     */
    function approveForGasless(uint256 tbtcAmount, uint256 tokenAmount, address token) 
        external 
    {
        tbtcToken.approve(address(this), tbtcAmount);
        IERC20(token).approve(address(this), tokenAmount);
    }
    
    function verifyRequest(GaslessSwapRequest calldata request) 
        internal 
        pure 
        returns (bool) 
    {
        // Implement EIP-712 signature verification
        return true; // Placeholder
    }
    
    function addRelayer(address relayer) external onlyOwner {
        approvedRelayers[relayer] = true;
    }
    
    function removeRelayer(address relayer) external onlyOwner {
        approvedRelayers[relayer] = false;
    }
    
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
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
