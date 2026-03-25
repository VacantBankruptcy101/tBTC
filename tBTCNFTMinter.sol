// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/AccessControl.sol";
import "./tBTCToken.sol";

contract tBTCNFTMinter is ERC721, ERC721Enumerable, ReentrancyGuard, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    using Strings for uint256;
    
    tBTCToken public tBTCToken;
    uint256 private _tokenIdCounter;
    
    enum Tier { Bronze, Silver, Gold, Platinum, Diamond }
    
    struct BurnTier {
        uint256 burnAmount;
        uint256 maxSupply;
        uint256 minted;
        string baseURI;
    }
    
    mapping(Tier => BurnTier) public tiers;
    mapping(uint256 => Tier) public tokenTier;
    mapping(address => uint256) public totalBurned;
    
    bool public isTestnet;
    uint256 public testnetMultiplier;
    
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    event TokensBurned(
        address indexed burner,
        uint256 amount,
        Tier tier,
        uint256 tokenId
    );

    constructor(
        address _tBTCToken,
        string memory _name,
        string memory _symbol,
        bool _isTestnet
    ) ERC721(_name, _symbol) {
        tBTCToken = tBTCToken(_tBTCToken);
        isTestnet = _isTestnet;
        testnetMultiplier = _isTestnet ? 100 : 1;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        
        _setupTier(Tier.Bronze, 0.001 ether * testnetMultiplier, 1000, "https://api.example.com/nft/bronze/");
        _setupTier(Tier.Silver, 0.01 ether * testnetMultiplier, 500, "https://api.example.com/nft/silver/");
        _setupTier(Tier.Gold, 0.1 ether * testnetMultiplier, 100, "https://api.example.com/nft/gold/");
        _setupTier(Tier.Platinum, 1 ether * testnetMultiplier, 20, "https://api.example.com/nft/platinum/");
        _setupTier(Tier.Diamond, 10 ether * testnetMultiplier, 5, "https://api.example.com/nft/diamond/");
    }
    
    function _setupTier(
        Tier _tier,
        uint256 _amount,
        uint256 _supply,
        string memory _uri
    ) internal {
        tiers[_tier] = BurnTier({
            burnAmount: _amount,
            maxSupply: _supply,
            minted: 0,
            baseURI: _uri
        });
    }
    
    function burnAndMint(Tier _tier) external nonReentrant returns (uint256) {
        BurnTier storage tier = tiers[_tier];
        require(tier.minted < tier.maxSupply, "Tier sold out");
        
        uint256 burnAmount = tier.burnAmount;
        
        require(
            tBTCToken.transferFrom(msg.sender, BURN_ADDRESS, burnAmount),
            "Transfer failed"
        );
        
        _tokenIdCounter++;
        uint256 newTokenId = _tokenIdCounter;
        
        _safeMint(msg.sender, newTokenId);
        tokenTier[newTokenId] = _tier;
        tier.minted++;
        totalBurned[msg.sender] += burnAmount;
        
        emit TokensBurned(msg.sender, burnAmount, _tier, newTokenId);
        
        return newTokenId;
    }
    
    function batchBurnAndMint(Tier _tier, uint256 _quantity) 
        external 
        nonReentrant 
        returns (uint256[] memory) 
    {
        require(_quantity > 0 && _quantity <= 10, "Invalid quantity");
        
        BurnTier storage tier = tiers[_tier];
        require(tier.minted + _quantity <= tier.maxSupply, "Exceeds supply");
        
        uint256 totalBurn = tier.burnAmount * _quantity;
        
        require(
            tBTCToken.transferFrom(msg.sender, BURN_ADDRESS, totalBurn),
            "Transfer failed"
        );
        
        uint256[] memory tokenIds = new uint256[](_quantity);
        
        for (uint i = 0; i < _quantity; i++) {
            _tokenIdCounter++;
            uint256 newTokenId = _tokenIdCounter;
            
            _safeMint(msg.sender, newTokenId);
            tokenTier[newTokenId] = _tier;
            tokenIds[i] = newTokenId;
            
            emit TokensBurned(msg.sender, tier.burnAmount, _tier, newTokenId);
        }
        
        tier.minted += _quantity;
        totalBurned[msg.sender] += totalBurn;
        
        return tokenIds;
    }
    
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        require(_exists(tokenId), "Token does not exist");
        
        Tier tier = tokenTier[tokenId];
        BurnTier memory tierData = tiers[tier];
        
        return string(abi.encodePacked(
            tierData.baseURI,
            tokenId.toString(),
            ".json"
        ));
    }
    
    function updateTier(
        Tier _tier,
        uint256 _newAmount,
        uint256 _newSupply,
        string calldata _newURI
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        BurnTier storage tier = tiers[_tier];
        require(_newSupply >= tier.minted, "Supply below minted");
        
        tier.burnAmount = _newAmount;
        tier.maxSupply = _newSupply;
        tier.baseURI = _newURI;
    }
    
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
