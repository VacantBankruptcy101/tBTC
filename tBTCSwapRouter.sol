// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/utils/cryptography/ECDSA.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
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

    struct GaslessSwapRequest {
        SwapParams params;
        uint256 tbtcGasPayment;
        uint256 nonce;
        bytes signature;
    }

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,address verifyingContract)");
    bytes32 private constant _SWAP_TYPEHASH =
        keccak256(
            "GaslessSwapRequest(address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,address recipient,uint256 deadline,uint256 nonce,uint256 tbtcGasPayment,uint8 dexVersion,uint24 feeTier)"
        );

    IUniswapV2Router public immutable uniswapV2Router;
    IERC20 public immutable tbtcToken;

    mapping(address => bool) public approvedRelayers;
    mapping(address => uint256) public userNonces;

    uint256 public constant MAX_SLIPPAGE_BASIS_POINTS = 1000;
    uint256 public defaultSlippageBps = 50;
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

    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        DEXVersion dexVersion
    );

    constructor(address _v2Router, address _tbtcToken) {
        require(_v2Router != address(0), "Zero router");
        require(_tbtcToken != address(0), "Zero tBTC");

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
        require(params.amountIn > 0, "Zero amount");
        require(params.tokenIn != address(0) && params.tokenOut != address(0), "Zero token");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenIn).safeIncreaseAllowance(address(uniswapV2Router), params.amountIn);

        address[] memory path = new address[](2);
        path[0] = params.tokenIn;
        path[1] = params.tokenOut;

        uint256[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            params.amountIn,
            params.amountOutMin,
            path,
            params.recipient,
            params.deadline
        );

        amountOut = amounts[amounts.length - 1];
        require(amountOut >= params.amountOutMin, "Slippage exceeded");

        emit StandardSwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut
        );

        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            params.dexVersion
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
        require(request.params.amountIn > 0, "Zero amount");
        require(request.params.tokenIn != address(0) && request.params.tokenOut != address(0), "Zero token");
        require(userNonces[request.params.recipient] == request.nonce, "Invalid nonce");
        require(verifyRequest(request), "Invalid signature");

        userNonces[request.params.recipient]++;

        require(request.tbtcGasPayment > 0, "Zero gas payment");
        require(
            tbtcToken.transferFrom(request.params.recipient, msg.sender, request.tbtcGasPayment),
            "Gas payment failed"
        );

        IERC20(request.params.tokenIn).safeTransferFrom(
            request.params.recipient,
            address(this),
            request.params.amountIn
        );
        IERC20(request.params.tokenIn).safeIncreaseAllowance(
            address(uniswapV2Router),
            request.params.amountIn
        );

        address[] memory path = new address[](2);
        path[0] = request.params.tokenIn;
        path[1] = request.params.tokenOut;

        uint256[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            request.params.amountIn,
            request.params.amountOutMin,
            path,
            request.params.recipient,
            request.params.deadline
        );

        amountOut = amounts[amounts.length - 1];
        require(amountOut >= request.params.amountOutMin, "Slippage exceeded");

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

    function getExpectedOutput(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        require(tokenIn != address(0) && tokenOut != address(0), "Zero token");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = uniswapV2Router.getAmountsOut(amountIn, path);
        return amounts[1];
    }

    function approveForGasless(address token, uint256 amount) external {
        IERC20(token).safeIncreaseAllowance(address(this), amount);
    }

    function verifyRequest(GaslessSwapRequest calldata request) internal view returns (bool) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        _SWAP_TYPEHASH,
                        request.params.tokenIn,
                        request.params.tokenOut,
                        request.params.amountIn,
                        request.params.amountOutMin,
                        request.params.recipient,
                        request.params.deadline,
                        request.nonce,
                        request.tbtcGasPayment,
                        uint8(request.params.dexVersion),
                        request.params.feeTier
                    )
                )
            )
        );

        bytes memory signature = request.signature;
        address signer = ECDSA.recover(digest, signature);
        return signer == request.params.recipient;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("tBTCSwapRouter"),
                keccak256("1"),
                address(this)
            )
        );
    }

    function addRelayer(address relayer) external onlyOwner {
        require(relayer != address(0), "Zero relayer");
        approvedRelayers[relayer] = true;
    }

    function removeRelayer(address relayer) external onlyOwner {
        approvedRelayers[relayer] = false;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        if (amount == 0) return;
        IERC20(token).safeTransfer(owner(), amount);
    }
}
