// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title TokenBurnNFTMinter
 * @notice Contract that burns ERC-20 tokens and mints NFTs in exchange
 * @dev Users must approve token spending before calling mint functions
 */
contract TokenBurnNFTMinter is 
    ERC721, 
    ERC721Enumerable, 
    ERC721URIStorage, 
    Ownable, 
    ReentrancyGuard, 
    Pausable 
{
    using SafeERC20 for IERC20;

    // ============ State Variables ============
    
    IERC20 public immutable burnToken;
    uint256 public immutable burnAmountPerNFT;
    uint256 public maxSupply;
    uint256 public totalMinted;
    string public baseTokenURI;
    
    // Mapping to track how many NFTs an address has minted
    mapping(address => uint256) public mintedCount;
    uint256 public maxMintPerWallet;
    
    // ============ Events ============
    
    event NFTMinted(
        address indexed minter,
        uint256 indexed tokenId,
        uint256 burnedAmount
    );
    
    event TokensBurned(
        address indexed burner,
        uint256 amount
    );
    
    event MaxSupplyUpdated(uint256 newMaxSupply);
    event BurnAmountUpdated(uint256 newBurnAmount);
    event BaseURIUpdated(string newBaseURI);
    
    // ============ Errors ============
    
    error InsufficientTokenBalance(address account, uint256 required);
    error MaxSupplyReached(uint256 requested, uint256 maxSupply);
    error MaxMintPerWalletReached(address account, uint256 limit);
    error TokenTransferFailed();
    error InvalidAmount();
    error InvalidAddress();
    
    // ============ Constructor ============
    
    constructor(
        address _burnToken,
        uint256 _burnAmountPerNFT,
        uint256 _maxSupply,
        uint256 _maxMintPerWallet,
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        if (_burnToken == address(0)) revert InvalidAddress();
        if (_burnAmountPerNFT == 0) revert InvalidAmount();
        
        burnToken = IERC20(_burnToken);
        burnAmountPerNFT = _burnAmountPerNFT;
        maxSupply = _maxSupply;
        maxMintPerWallet = _maxMintPerWallet;
        baseTokenURI = _baseTokenURI;
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Mint a single NFT by burning tokens
     * @param _tokenURI URI for the NFT metadata
     */
    function mint(
        string memory _tokenURI
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _mintSingleNFT(msg.sender, _tokenURI);
    }
    
    /**
     * @notice Mint multiple NFTs in one transaction
     * @param _quantity Number of NFTs to mint
     * @param _tokenURIs Array of URIs for each NFT
     */
    function mintBatch(
        uint256 _quantity,
        string[] memory _tokenURIs
    ) external nonReentrant whenNotPaused returns (uint256[] memory) {
        if (_quantity == 0) revert InvalidAmount();
        if (_quantity != _tokenURIs.length) revert InvalidAmount();
        
        uint256[] memory tokenIds = new uint256[](_quantity);
        
        for (uint256 i = 0; i < _quantity; i++) {
            tokenIds[i] = _mintSingleNFT(msg.sender, _tokenURIs[i]);
        }
        
        return tokenIds;
    }
    
    /**
     * @notice Admin function to mint without burning (for promotions/airdrops)
     * @param _to Recipient address
     * @param _tokenURI URI for the NFT metadata
     */
    function adminMint(
        address _to,
        string memory _tokenURI
    ) external onlyOwner returns (uint256) {
        return _mintSingleNFT(_to, _tokenURI);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Internal function to handle minting logic with token burn
     */
    function _mintSingleNFT(
        address _to,
        string memory _tokenURI
    ) internal returns (uint256) {
        // Check supply
        if (totalMinted >= maxSupply) {
            revert MaxSupplyReached(totalMinted + 1, maxSupply);
        }
        
        // Check per-wallet limit (skip for admin mints)
        if (msg.sender == _to) {
            if (mintedCount[_to] >= maxMintPerWallet) {
                revert MaxMintPerWalletReached(_to, maxMintPerWallet);
            }
        }
        
        // Check and burn tokens (skip for admin mints)
        if (msg.sender == _to) {
            uint256 requiredBalance = burnAmountPerNFT;
            uint256 userBalance = burnToken.balanceOf(_to);
            
            if (userBalance < requiredBalance) {
                revert InsufficientTokenBalance(_to, requiredBalance);
            }
            
            // Burn tokens by sending to dead address or actual burn
            burnToken.safeTransferFrom(_to, address(0xdead), requiredBalance);
            
            emit TokensBurned(_to, requiredBalance);
        }
        
        // Mint NFT
        uint256 newTokenId = totalMinted + 1;
        totalMinted++;
        mintedCount[_to]++;
        
        _safeMint(_to, newTokenId);
        _setTokenURI(newTokenId, _tokenURI);
        
        emit NFTMinted(_to, newTokenId, msg.sender == _to ? burnAmountPerNFT : 0);
        
        return newTokenId;
    }
    
    // ============ Admin Functions ============
    
    function setMaxSupply(uint256 _newMaxSupply) external onlyOwner {
        if (_newMaxSupply < totalMinted) revert InvalidAmount();
        maxSupply = _newMaxSupply;
        emit MaxSupplyUpdated(_newMaxSupply);
    }
    
    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseTokenURI = _newBaseURI;
        emit BaseURIUpdated(_newBaseURI);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency function to recover accidentally sent ERC20 tokens
     * @param _token Token to recover
     * @param _amount Amount to recover
     */
    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), _amount);
    }
    
    // ============ View Functions ============
    
    function remainingSupply() external view returns (uint256) {
        return maxSupply - totalMinted;
    }
    
    function canMint(address _account) external view returns (bool) {
        if (totalMinted >= maxSupply) return false;
        if (mintedCount[_account] >= maxMintPerWallet) return false;
        return burnToken.balanceOf(_account) >= burnAmountPerNFT;
    }
    
    // ============ Overrides ============
    
    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }
    
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override(ERC721, ERC721URIStorage) 
        returns (string memory) 
    {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }
    
    function _burn(uint256 tokenId) 
        internal 
        override(ERC721, ERC721URIStorage) 
    {
        super._burn(tokenId);
    }
}
