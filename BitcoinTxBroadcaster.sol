// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/Pausable.sol";

contract BitcoinTxBroadcaster is AccessControl, Pausable {
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    struct RawTransaction {
        bytes txData;
        bytes32 txHash;
        uint256 feeRate;
        uint256 timestamp;
        TxStatus status;
        uint256 rbfSequence;
        bytes32 replacesTx;
    }
    
    enum TxStatus { Pending, Broadcast, Confirmed, Failed, Replaced }
    
    mapping(bytes32 => RawTransaction) public transactions;
    mapping(bytes32 => bool) public isUTXOSpent;
    mapping(bytes32 => uint256) public mempoolEntryTime;
    mapping(bytes32 => uint256) public confirmationHeight;
    
    uint256 public recommendedFeeRate;
    uint256 public minFeeRate;
    uint256 public maxFeeRate;
    
    event TransactionSubmitted(
        bytes32 indexed txHash,
        uint256 feeRate,
        bool isRBF
    );
    
    event TransactionBroadcast(
        bytes32 indexed txHash,
        uint256 broadcastTime
    );
    
    event TransactionConfirmed(
        bytes32 indexed txHash,
        uint256 blockHeight,
        uint256 confirmations
    );
    
    event RBFReplaced(
        bytes32 indexed oldTxHash,
        bytes32 indexed newTxHash,
        uint256 newFeeRate
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        
        minFeeRate = 1;
        maxFeeRate = 1000;
    }
    
    function submitTransaction(
        bytes calldata _txData,
        uint256 _feeRate,
        bool _isRBF,
        bytes32 _replacesTx
    ) external onlyRole(RELAYER_ROLE) whenNotPaused returns (bytes32 txHash) {
        require(_feeRate >= minFeeRate && _feeRate <= maxFeeRate, "Invalid fee rate");
        
        txHash = keccak256(_txData);
        require(transactions[txHash].timestamp == 0, "TX already exists");
        
        if (_isRBF && _replacesTx != bytes32(0)) {
            require(
                transactions[_replacesTx].status == TxStatus.Pending ||
                transactions[_replacesTx].status == TxStatus.Broadcast,
                "Cannot replace"
            );
            
            RawTransaction storage oldTx = transactions[_replacesTx];
            require(_feeRate > oldTx.feeRate, "Insufficient fee bump");
            
            oldTx.status = TxStatus.Replaced;
            emit RBFReplaced(_replacesTx, txHash, _feeRate);
        }
        
        transactions[txHash] = RawTransaction({
            txData: _txData,
            txHash: txHash,
            feeRate: _feeRate,
            timestamp: block.timestamp,
            status: TxStatus.Pending,
            rbfSequence: _isRBF ? 1 : 0,
            replacesTx: _replacesTx
        });
        
        emit TransactionSubmitted(txHash, _feeRate, _isRBF);
    }
    
    function reportBroadcast(bytes32 _txHash) external onlyRole(ORACLE_ROLE) {
        RawTransaction storage tx = transactions[_txHash];
        require(tx.timestamp > 0, "TX not found");
        require(tx.status == TxStatus.Pending, "Invalid status");
        
        tx.status = TxStatus.Broadcast;
        mempoolEntryTime[_txHash] = block.timestamp;
        
        emit TransactionBroadcast(_txHash, block.timestamp);
    }
    
    function reportConfirmation(
        bytes32 _txHash,
        uint256 _blockHeight,
        uint256 _confirmations
    ) external onlyRole(ORACLE_ROLE) {
        RawTransaction storage tx = transactions[_txHash];
        require(tx.status == TxStatus.Broadcast, "Not broadcast");
        
        tx.status = TxStatus.Confirmed;
        confirmationHeight[_txHash] = _blockHeight;
        
        emit TransactionConfirmed(_txHash, _blockHeight, _confirmations);
    }
    
    function updateFeeRate(uint256 _newRate) external onlyRole(ORACLE_ROLE) {
        require(_newRate >= minFeeRate && _newRate <= maxFeeRate, "Out of bounds");
        recommendedFeeRate = _newRate;
    }
    
    function getTransactionData(bytes32 _txHash) external view returns (bytes memory) {
        return transactions[_txHash].txData;
    }
    
    function checkUTXOStatus(bytes32 _utxoHash) external view returns (bool) {
        return isUTXOSpent[_utxoHash];
    }
    
    function markUTXOSpent(bytes32 _utxoHash) external onlyRole(ORACLE_ROLE) {
        isUTXOSpent[_utxoHash] = true;
    }
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
