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
    Transaction[] private transactions;
    mapping(uint256 => mapping(address => bool)) private isOwner;
    mapping(uint => mapping(address => bool)) private isConfirmed;
    mapping(uint256 => uint256) private shareAMountPerTokenId;
    mapping(uint256 => uint256) private totalSharesOfFractionalBuyerPerTokenId;
    // Mapping the address of admin
    mapping(uint256 => NFT) public idToNFT;
    // NFT ID => owner
    mapping(uint256 => address payable) public idToOwner;
    // NFT ID => Price
    mapping(uint256 => uint256) public idToPrice;
    // NFT ID => share value
    mapping(uint256 => uint256) public idToShareValue;

    struct Transaction {
        address from;
        address to;
        uint256 price;
        uint256 tokenId;
        bool executed;
        uint numConfirmationsRequired;
        uint numConfirmations;
    }

    struct NFT {
        uint256 tokenID;
        address payable owner;
        address[] fractionalBuyersList;
        uint256 numOfFractionalBuyers;
        uint256 price;
    }

    modifier onlyFractionalOwners(uint256 _tokenId) {
        require(isOwner[_tokenId][msg.sender], "not fractionalOwner");
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

    // Lock NFT in fractional contract
    function lockNFT(
        uint256 _tokenId,
        uint256 _sharesAmount,
        uint256 _price,
        address _tokenAddress
    ) public whenNotPaused {
        require(_sharesAmount > 0, "Invalid sharesAmount");
        require(_price > 0, "Invalid price");
        require(_tokenAddress != address(0), "Invalid tokenAddress");
        // Transfer NFT to contract
        _transferNFT(msg.sender, address(this), _tokenId);
        tokenAddress = IERC20(_tokenAddress);
        require(tokenAddress.balanceOf(msg.sender) > 0, "Insufficient token balance");
        require(
            tokenAddress.allowance(msg.sender, address(this)) >= _sharesAmount,
            "Check the token allowance"
        );
        shareAMountPerTokenId[_tokenId] = _sharesAmount;
        // Transfer tokens to this contract address
        tokenAddress.transferFrom(msg.sender, address(this), _sharesAmount);
        // Update mapping
        idToPrice[_tokenId] = _price;
        idToNFT[_tokenId].owner = payable(address(this));
        idToNFT[_tokenId].price = idToPrice[_tokenId];
        idToOwner[_tokenId] = payable(msg.sender);
        // Update share value
        uint256 _pricePerShare = idToPrice[_tokenId];
        idToShareValue[_tokenId] = _pricePerShare.div(_sharesAmount);
    }

    // Function for user to buy shares of NFT and hold ERC20 as validation token of the purchase
    function buyFractionalSharesOfNft(uint256 _tokenId, uint256 _totalShares)
        public
        payable whenNotPaused
    {   
        require(_totalShares > 0, "Invalid totalShares");
        require(
            msg.value >= idToShareValue[_tokenId].mul(_totalShares),
            "Insufficient funds"
        );
        require(shareAMountPerTokenId[_tokenId] != 0, "Shares for respective token is over");
        // User sends ETH to owner
        address payable nftOwner = idToOwner[_tokenId];
        uint256 _amount = idToShareValue[_tokenId].mul(_totalShares);
        nftOwner.transfer(_amount);
        tokenAddress.transfer(msg.sender, _totalShares);
        idToNFT[_tokenId].fractionalBuyersList.push(msg.sender);
        totalSharesOfFractionalBuyerPerTokenId[_tokenId] = _totalShares;
        shareAMountPerTokenId[_tokenId] = shareAMountPerTokenId[_tokenId] - totalSharesOfFractionalBuyerPerTokenId[_tokenId];
        idToNFT[_tokenId].numOfFractionalBuyers += 1;
        isOwner[_tokenId][msg.sender] = true;
    }

    function submitTransaction(
        address _to,
        uint256 _tokenId,
        uint256 _price,
        uint _numConfirmationsRequired
    ) external payable onlyFractionalOwners(_tokenId) whenNotPaused {
        require(_to != address(0), "Invalid to address");
        require(_price > 0, "Price cannot be 0");
        require(_price == msg.value, "Invalid price");
        require(_numConfirmationsRequired > 0 && _numConfirmationsRequired <= idToNFT[_tokenId].fractionalBuyersList.length, "invalid number of required confirmations");
        uint txIndex = transactions.length;
        idToNFT[_tokenId].price = _price;
        transactions.push(
            Transaction({
                from: msg.sender,
                to: _to,
                tokenId: _tokenId,
                price: _price,
                executed: false,
                numConfirmationsRequired: _numConfirmationsRequired,
                numConfirmations: 0
            })
        );
        emit SubmitTransaction(msg.sender, txIndex, _to, _tokenId, _price);
    }

    function confirmTransaction(
        uint _txIndex,
        uint256 _tokenId
    ) public onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) notConfirmed(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        transaction.numConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    function executeTransaction(
        uint _txIndex, address _to, uint256 _tokenId, uint256 _price
    ) external onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        require(transaction.to == _to && transaction.price == _price && transaction.tokenId == _tokenId, "Invalid input");
        require(transaction.from == msg.sender, "Invalid fractional owner");
        require(_price != 0, "Insufficient amount");
        require(
            transaction.numConfirmations >= transaction.numConfirmationsRequired,
            "cannot execute tx"
        );
        require(_price != 0, "Value cannot be 0");
        emit ExecuteTransaction(msg.sender, _txIndex);
        uint256 newPrice = _price / idToNFT[_tokenId].fractionalBuyersList.length;
        for (uint i = 0; i < idToNFT[_tokenId].numOfFractionalBuyers; i++) {
            address payable fractionalBuyersofNft = payable(idToNFT[_tokenId].fractionalBuyersList[i]);
            fractionalBuyersofNft.transfer(newPrice);
        }
        idToNFT[_tokenId].owner = payable(_to);
        _transfer(address(this), _to, _tokenId);
    }

    function revokeConfirmation(
        uint _txIndex,
        uint256 _tokenId
    ) public onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) whenNotPaused {
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
            uint numConfirmationsRequired,
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
            transaction.numConfirmationsRequired,
            transaction.numConfirmations
        );
    }

    function pause() public {
        _pause();
    }

    function unpause() public {
        _unpause();
    }

    function changeNumConfirmationsRequired(uint _txIndex, uint256 _tokenId, uint256 _numConfirmationsRequired) public whenNotPaused onlyFractionalOwners(_tokenId) notExecuted(_txIndex) {
        Transaction storage transaction = transactions[_txIndex];
        require(transaction.from == msg.sender, "Owner who submitted the transaction can only call this function");
        require(transaction.numConfirmationsRequired != _numConfirmationsRequired, "Numbers of required confirmations is already same");
        transaction.numConfirmationsRequired = _numConfirmationsRequired;
    }

     function fetchNFTs(uint256 _tokenId) public view returns (NFT memory) {
        return idToNFT[_tokenId];
    }

    function getFractionalBuyersList(uint256 _tokenId) public view returns(address[] memory){
        return idToNFT[_tokenId].fractionalBuyersList;
    }
}
