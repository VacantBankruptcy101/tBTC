// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts@4.9.6/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts@4.9.6/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.6/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.6/security/Pausable.sol";

/**
 * @title NFTIncentiveToken
 * @notice ERC-20 reward token whose minting is controlled by its owner.
 * The NFT minter contract owns this token and controls reward issuance.
 */
contract NFTIncentiveToken is ERC20, Ownable {
    constructor() ERC20("NFT Incentive Token", "NIT") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/**
 * @title TokenBurnNFTMinter
 * @notice Burns an existing ERC-20 token to mint NFTs and rewards NFT
 *         minters and transfer participants with a separate ERC-20 token.
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

    uint256 public constant MINT_REWARD = 100 ether;
    uint256 public constant TRANSFER_REWARD_PER_WALLET = 50 ether;

    IERC20 public immutable burnToken;
    NFTIncentiveToken public immutable incentiveToken;
    uint256 public immutable burnAmountPerNFT;

    uint256 public maxSupply;
    uint256 public totalMinted;
    string public baseTokenURI;

    mapping(address => uint256) public mintedCount;
    uint256 public maxMintPerWallet;

    event NFTMinted(
        address indexed minter,
        uint256 indexed tokenId,
        uint256 burnedAmount
    );
    event TokensBurned(address indexed burner, uint256 amount);
    event IncentiveRewarded(address indexed account, uint256 amount);
    event MaxSupplyUpdated(uint256 newMaxSupply);
    event BaseURIUpdated(string newBaseURI);

    error InsufficientTokenBalance(address account, uint256 required);
    error MaxSupplyReached(uint256 requested, uint256 maxSupply);
    error MaxMintPerWalletReached(address account, uint256 limit);
    error InvalidAmount();
    error InvalidAddress();

    constructor(
        address _burnToken,
        uint256 _burnAmountPerNFT,
        uint256 _maxSupply,
        uint256 _maxMintPerWallet,
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI
    ) ERC721(_name, _symbol) Ownable() {
        if (_burnToken == address(0)) revert InvalidAddress();
        if (_burnAmountPerNFT == 0) revert InvalidAmount();

        burnToken = IERC20(_burnToken);
        burnAmountPerNFT = _burnAmountPerNFT;
        maxSupply = _maxSupply;
        maxMintPerWallet = _maxMintPerWallet;
        baseTokenURI = _baseTokenURI;

        // This contract becomes the incentive token's owner and sole minter.
        incentiveToken = new NFTIncentiveToken();
    }

    /**
     * @notice Mint one NFT by burning the required amount of burnToken.
     */
    function mint(string memory _tokenURI)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return _mintSingleNFT(msg.sender, _tokenURI, true);
    }

    /**
     * @notice Mint multiple NFTs by burning the required tokens for each.
     */
    function mintBatch(uint256 _quantity, string[] memory _tokenURIs)
        external
        nonReentrant
        whenNotPaused
        returns (uint256[] memory)
    {
        if (_quantity == 0 || _quantity != _tokenURIs.length) {
            revert InvalidAmount();
        }

        uint256[] memory tokenIds = new uint256[](_quantity);

        for (uint256 i = 0; i < _quantity; i++) {
            tokenIds[i] = _mintSingleNFT(msg.sender, _tokenURIs[i], true);
        }

        return tokenIds;
    }

    /**
     * @notice Owner-only promotional mint; does not burn tokens or enforce
     *         the per-wallet mint limit.
     */
    function adminMint(address _to, string memory _tokenURI)
        external
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        if (_to == address(0)) revert InvalidAddress();
        return _mintSingleNFT(_to, _tokenURI, false);
    }

    function _mintSingleNFT(
        address _to,
        string memory _tokenURI,
        bool _burnTokens
    ) internal returns (uint256) {
        if (_to == address(0)) revert InvalidAddress();

        if (totalMinted >= maxSupply) {
            revert MaxSupplyReached(totalMinted + 1, maxSupply);
        }

        if (_burnTokens && mintedCount[_to] >= maxMintPerWallet) {
            revert MaxMintPerWalletReached(_to, maxMintPerWallet);
        }

        if (_burnTokens) {
            uint256 userBalance = burnToken.balanceOf(_to);

            if (userBalance < burnAmountPerNFT) {
                revert InsufficientTokenBalance(_to, burnAmountPerNFT);
            }

            burnToken.safeTransferFrom(
                _to,
                address(0xdead),
                burnAmountPerNFT
            );

            emit TokensBurned(_to, burnAmountPerNFT);
        }

        uint256 newTokenId = totalMinted + 1;
        totalMinted++;
        mintedCount[_to]++;

        _safeMint(_to, newTokenId);
        _setTokenURI(newTokenId, _tokenURI);

        emit NFTMinted(
            _to,
            newTokenId,
            _burnTokens ? burnAmountPerNFT : 0
        );

        return newTokenId;
    }

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

    function recoverERC20(address _token, uint256 _amount)
        external
        onlyOwner
    {
        if (_token == address(0)) revert InvalidAddress();
        IERC20(_token).safeTransfer(owner(), _amount);
    }

    function remainingSupply() external view returns (uint256) {
        return maxSupply - totalMinted;
    }

    function canMint(address _account) external view returns (bool) {
        if (totalMinted >= maxSupply) return false;
        if (mintedCount[_account] >= maxMintPerWallet) return false;
        return burnToken.balanceOf(_account) >= burnAmountPerNFT;
    }

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

        if (to == address(0)) {
            return;
        }

        if (from == address(0)) {
            // Initial NFT mint: reward its recipient with 100 tokens.
            incentiveToken.mint(to, MINT_REWARD);
            emit IncentiveRewarded(to, MINT_REWARD);
        } else {
            // NFT transfer: reward both the sender and recipient with 50 each.
            incentiveToken.mint(from, TRANSFER_REWARD_PER_WALLET);
            incentiveToken.mint(to, TRANSFER_REWARD_PER_WALLET);

            emit IncentiveRewarded(from, TRANSFER_REWARD_PER_WALLET);
            emit IncentiveRewarded(to, TRANSFER_REWARD_PER_WALLET);
        }
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }
}
