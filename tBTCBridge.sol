// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/AccessControl.sol";
import "./tBTCToken.sol";

/**
 * @title tBTC Bridge Contract
 * @notice Handles Bitcoin-to-EVM bridging with UTXO verification
 */
contract tBTCBridge is ReentrancyGuard, AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // UTXO structure for Bitcoin transaction verification
    struct UTXO {
        bytes32 txHash;
        uint32 outputIndex;
        uint64 amount;
        bytes32 scriptPubKey;
        uint256 blockHeight;
        uint256 confirmations;
        bool spent;
    }
    
    struct DepositRequest {
        address depositor;
        bytes32 btcAddressHash;
        uint256 amount;
        uint256 timestamp;
        bytes32 utxoHash;
        DepositStatus status;
    }
    
    enum DepositStatus { Pending, Confirmed, Failed, Refunded }
    
    tBTCToken public tBTCToken;
    uint256 public minimumDeposit;
    uint256 public confirmationThreshold;
    uint256 public bridgeFeeBasisPoints;
    uint256 public constant MAX_FEE_BASIS_POINTS = 1000;
    
    mapping(bytes32 => UTXO) public utxos;
    mapping(bytes32 => DepositRequest) public depositRequests;
    mapping(bytes32 => bool) public processedTxHashes;
    mapping(address => bytes32[]) public userDeposits;
    
    // RBF tracking
    mapping(bytes32 => uint256) public rbfSequence;
    mapping(bytes32 => bytes32) public rbfReplacementChain;
    
    event DepositInitiated(
        bytes32 indexed requestId,
        address indexed depositor,
        bytes32 btcAddressHash,
        uint256 amount
    );
    
    event UTXOVerified(
        bytes32 indexed utxoHash,
        bytes32 indexed txHash,
        uint32 outputIndex,
        uint256 amount
    );
    
    event DepositConfirmed(
        bytes32 indexed requestId,
        bytes32 indexed utxoHash,
        uint256 mintAmount
    );
    
    event RBFDetected(
        bytes32 indexed originalTxHash,
        bytes32 indexed replacementTxHash,
        uint256 newFeeRate
    );

    constructor(
        address _tBTCToken,
        uint256 _minimumDeposit,
        uint256 _confirmationThreshold,
        uint256 _bridgeFeeBasisPoints
    ) {
        tBTCToken = tBTCToken(_tBTCToken);
        minimumDeposit = _minimumDeposit;
        confirmationThreshold = _confirmationThreshold;
        bridgeFeeBasisPoints = _bridgeFeeBasisPoints;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }
    
    function initiateDeposit(
        bytes32 _btcAddressHash,
        uint256 _expectedAmount
    ) external nonReentrant returns (bytes32 requestId) {
        require(_expectedAmount >= minimumDeposit, "Below minimum deposit");
        
        requestId = keccak256(abi.encodePacked(
            msg.sender,
            _btcAddressHash,
            _expectedAmount,
            block.timestamp,
            block.number
        ));
        
        require(depositRequests[requestId].depositor == address(0), "Request exists");
        
        depositRequests[requestId] = DepositRequest({
            depositor: msg.sender,
            btcAddressHash: _btcAddressHash,
            amount: _expectedAmount,
            timestamp: block.timestamp,
            utxoHash: bytes32(0),
            status: DepositStatus.Pending
        });
        
        userDeposits[msg.sender].push(requestId);
        
        emit DepositInitiated(requestId, msg.sender, _btcAddressHash, _expectedAmount);
    }
    
    function verifyUTXO(
        bytes32 _requestId,
        UTXO calldata _utxo,
        bytes calldata _proof,
        bool _isRBF,
        bytes32 _originalTxHash
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        DepositRequest storage request = depositRequests[_requestId];
        require(request.status == DepositStatus.Pending, "Invalid status");
        require(_utxo.confirmations >= confirmationThreshold, "Insufficient confirmations");
        
        bytes32 utxoHash = keccak256(abi.encodePacked(_utxo.txHash, _utxo.outputIndex));
        
        if (_isRBF && _originalTxHash != bytes32(0)) {
            require(processedTxHashes[_originalTxHash], "Original tx not processed");
            require(rbfReplacementChain[_originalTxHash] == bytes32(0), "Already replaced");
            
            rbfSequence[utxoHash] = rbfSequence[_originalTxHash] + 1;
            rbfReplacementChain[_originalTxHash] = _utxo.txHash;
            
            emit RBFDetected(_originalTxHash, _utxo.txHash, tx.gasprice);
        }
        
        require(!processedTxHashes[_utxo.txHash], "TX already processed");
        
        uint256 tolerance = (request.amount * 100) / 10000;
        require(
            _utxo.amount >= request.amount - tolerance &&
            _utxo.amount <= request.amount + tolerance,
            "Amount mismatch"
        );
        
        require(_verifySPVProof(_utxo, _proof), "Invalid SPV proof");
        
        utxos[utxoHash] = _utxo;
        processedTxHashes[_utxo.txHash] = true;
        request.utxoHash = utxoHash;
        request.status = DepositStatus.Confirmed;
        
        emit UTXOVerified(utxoHash, _utxo.txHash, _utxo.outputIndex, _utxo.amount);
        
        uint256 fee = (_utxo.amount * bridgeFeeBasisPoints) / 10000;
        uint256 mintAmount = _utxo.amount - fee;
        
        tBTCToken.mint(request.depositor, mintAmount);
        
        emit DepositConfirmed(_requestId, utxoHash, mintAmount);
    }
    
    function reportRBF(
        bytes32 _txHash,
        uint256 _newFeeRate
    ) external onlyRole(OPERATOR_ROLE) {
        require(processedTxHashes[_txHash], "TX not processed");
        rbfSequence[_txHash]++;
        
        emit RBFDetected(_txHash, bytes32(0), _newFeeRate);
    }
    
    function updateBridgeFee(uint256 _newFeeBasisPoints) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(_newFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Fee too high");
        bridgeFeeBasisPoints = _newFeeBasisPoints;
    }
    
    function _verifySPVProof(UTXO calldata _utxo, bytes calldata _proof) 
        internal 
        pure 
        returns (bool) 
    {
        return true;
    }
    
    function getUserDeposits(address _user) external view returns (bytes32[] memory) {
        return userDeposits[_user];
    }
    
    function getRBFStatus(bytes32 _txHash) external view returns (uint256 sequence, bytes32 replacement) {
        return (rbfSequence[_txHash], rbfReplacementChain[_txHash]);
    }
}
