// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

contract FractionalNft is Pausable, ERC721{
    using SafeMath for uint256;
    IERC20 private tokenAddress;

    event Deposit(address indexed sender, uint amount, uint balance);
    event SubmitTransaction(
        address indexed owner,
        uint indexed txIndex,
        address indexed to,
        uint256 _price,
        uint256 _tokenId
    );
    event ConfirmTransaction(address indexed owner, uint indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint indexed txIndex);
    event TokenMint(address indexed to, uint256 indexed price, uint256 indexed tokenID);
    event TokenTransfered(
        address token,
        address from,
        address to,
        uint256 indexed value,
        uint256 indexed tokenId
    );

    address[] private owners;
    uint public numConfirmationsRequired;
    Transaction[] private transactions;
    mapping(address => bool) private isOwner;
    mapping(uint => mapping(address => bool)) private isConfirmed;
    mapping(uint256 => address) public fractionalBuyers;
    mapping(uint256 => uint256) private shareAMountPerTokenId;
    mapping(uint256 => uint256) private totalSharesOfFractionalBuyerPerTokenId;
    //mapping the address of admin
    mapping(uint256 => NFT) public idToNFT;
    // NFT ID => owner
    mapping(uint256 => address payable) public idToOwner;
    // NFT ID => Price
    mapping(uint256 => uint256) public idToPrice;
    // NFT ID => share value
    mapping(uint256 => uint256) public idToShareValue;
    // NFT id => ERC20 share
    mapping(uint256 => bool) private forSale;

    struct Transaction {
        address from;
        address to;
        uint256 price;
        uint256 tokenId;
        bool executed;
        uint numConfirmations;
    }

    struct NFT {
        uint256 tokenID;
        address payable owner;
        address[] fractionalBuyerss;
        uint256 numOfFractionalBuyers;
        uint256 price;
    }

    modifier onlyFractionalOwners() {
        require(isOwner[msg.sender], "not fractionalOwner");
        _;
    }

    modifier txExists(uint _txIndex) {
        require(_txIndex < transactions.length, "tx does not exist");
        _;
    }

    modifier notExecuted(uint _txIndex) {
        require(!transactions[_txIndex].executed, "tx already executed");
        _;
    }

    modifier notConfirmed(uint _txIndex) {
        require(!isConfirmed[_txIndex][msg.sender], "tx already confirmed");
        _;
    }

    constructor(string memory name, string memory symbol) ERC721(name, symbol){}

    function _transferNFT(
        address _sender,
        address _receiver,
        uint256 _tokenId
    ) internal {
        _mint(_sender, _tokenId);
        transferFrom(_sender, _receiver, _tokenId);
    }

    // lock NFT in fractional contract
    function lockNFT(
        uint256 _tokenId,
        uint256 _sharesAmount,
        uint256 _price,
        address _tokenAddress
    ) public whenNotPaused {
        // transfer NFT to contract
        _transferNFT(msg.sender, address(this), _tokenId);
        tokenAddress = IERC20(_tokenAddress);
        shareAMountPerTokenId[_tokenId] = _sharesAmount;
        // transfer tokens to this contract address
        tokenAddress.transferFrom(msg.sender, address(this), _sharesAmount);
        // update mapping
        idToPrice[_tokenId] = _price;
        // update share value
        uint256 _pricePerShare = idToPrice[_tokenId];
        idToShareValue[_tokenId] = _pricePerShare.div(_sharesAmount);
    }

    // function for user to buy shares of NFT and hold ERC20 as validation token of the purchase
    function buyFractionalSharesOfNft(uint256 _tokenId, uint256 _totalShares)
        public
        payable whenNotPaused
    {
        require(
            msg.value >= idToShareValue[_tokenId].mul(_totalShares),
            "Insufficient funds"
        );
        require(shareAMountPerTokenId[_tokenId] != 0, "Shares for respective token is over");
        // user sends ETH to owner
        address payable nftOwner = idToOwner[_tokenId];
        uint256 _amount = idToShareValue[_tokenId].mul(_totalShares);
        nftOwner.transfer(_amount);
        tokenAddress.transfer(msg.sender, _totalShares);
        fractionalBuyers[_tokenId] = msg.sender;
        idToNFT[_tokenId].fractionalBuyerss.push(fractionalBuyers[_tokenId]);
        totalSharesOfFractionalBuyerPerTokenId[_tokenId] = _totalShares;
        shareAMountPerTokenId[_tokenId] = shareAMountPerTokenId[_tokenId] - totalSharesOfFractionalBuyerPerTokenId[_tokenId];
        idToNFT[_tokenId].numOfFractionalBuyers += 1;
        isOwner[msg.sender] = true;
        console.log("numOfFractionalBuyers[_tokenId] ===>", idToNFT[_tokenId].numOfFractionalBuyers);
    }

    function submitTransaction(
        address _to,
        uint256 _tokenId,
        uint256 _price,
        uint _numConfirmationsRequired
    ) public onlyFractionalOwners whenNotPaused {
        require(
        _numConfirmationsRequired > 0 && _numConfirmationsRequired <= idToNFT[_tokenId].fractionalBuyerss.length, "invalid number of required confirmations");
        uint txIndex = transactions.length;
        transactions.push(
            Transaction({
                from: msg.sender,
                to: _to,
                tokenId: _tokenId,
                price: _price,
                executed: false,
                numConfirmations: 0
            })
        );
        numConfirmationsRequired = _numConfirmationsRequired;
        emit SubmitTransaction(msg.sender, txIndex, _to, _tokenId, _price);
    }

    function confirmTransaction(
        uint _txIndex
    ) public onlyFractionalOwners txExists(_txIndex) notExecuted(_txIndex) notConfirmed(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        transaction.numConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    function executeTransaction(
        uint _txIndex, address _to, uint256 _tokenId, uint256 _price
    ) payable public onlyFractionalOwners txExists(_txIndex) notExecuted(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        require(transaction.to == _to && transaction.price == _price && transaction.tokenId == _tokenId, "Invalid input");
        require(_price != 0, "Insufficient amount");
        require(
            transaction.numConfirmations >= numConfirmationsRequired,
            "cannot execute tx"
        );
        require(_price != 0, "Value cannot be 0");
        require(_price == msg.value, "No value matched");
        emit ExecuteTransaction(msg.sender, _txIndex);
        uint256 newPrice = _price / idToNFT[_tokenId].fractionalBuyerss.length;
        for (uint i = 0; i < idToNFT[_tokenId].numOfFractionalBuyers; i++) {
            address payable fractionalBuyersofNft = payable(idToNFT[_tokenId].fractionalBuyerss[i]);
            fractionalBuyersofNft.transfer(newPrice);
        }
        _transfer(address(this), _to, _tokenId);
    }

    function revokeConfirmation(
        uint _txIndex
    ) public onlyFractionalOwners txExists(_txIndex) notExecuted(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        require(isConfirmed[_txIndex][msg.sender], "tx not confirmed");
        transaction.numConfirmations -= 1;
        isConfirmed[_txIndex][msg.sender] = false;
        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    function getOwners() public view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() public view returns (uint) {
        return transactions.length;
    }

    function getTransaction(
        uint _txIndex
    )
        public
        view
        returns (
            address from,
            address to,
            uint256 price,
            uint256 tokenId,
            bool executed,
            uint numConfirmations
        )
    {
        Transaction storage transaction = transactions[_txIndex];
        return (
            transaction.from,
            transaction.to,
            transaction.price,
            transaction.tokenId,
            transaction.executed,
            transaction.numConfirmations
        );
    }

    function pause() public {
        _pause();
    }

    function unpause() public {
        _unpause();
    }

    function changeNumConfirmationsRequired(uint _txIndex, uint256 _numConfirmationsRequired) public whenNotPaused onlyFractionalOwners notExecuted(_txIndex) {
        Transaction storage transaction = transactions[_txIndex];
        require(transaction.from == msg.sender, "Owner who submitted the transaction can only call this function");
        require(numConfirmationsRequired != _numConfirmationsRequired, "Numbers of required confirmations is already same");
        numConfirmationsRequired = _numConfirmationsRequired;
    }

     function fetchNFTs(uint256 _tokenId) public view returns (NFT memory) {
        return idToNFT[_tokenId];
    }

    function getFractionalBuyers(uint256 _tokenId) public view returns(address){
        return fractionalBuyers[_tokenId];
    }
    
    function getTotalSharesPerTokenId(uint256 _tokenId) public view returns(address[] memory){
        return idToNFT[_tokenId].fractionalBuyerss;
    }
}
