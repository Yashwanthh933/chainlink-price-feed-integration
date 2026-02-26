// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PriceConverter} from "./PriceConverter.sol";

/// @title TeaShop
/// @author Yashh
/// @notice A decentralized shop that accepts ETH payments at live USD prices via Chainlink
/// @dev Prices are stored internally in USD with 18 decimal precision (e.g. $5 = 5e18).
///      Buyers pay in ETH. The contract uses Chainlink ETH/USD price feed to determine
///      how much ETH is required at the time of purchase.
///
///      Price flow:
///        Owner sets price:   addItem("tea", 5)   → stored as 5e18 (USD, 18 dec)
///        Buyer queries:      getItemPriceInEth(0) → returns wei equivalent at live price
///        Buyer pays:         buyItem{value: X}(0) → X compared against getItemPriceInEth
///        Excess refunded:    if msg.value > required ETH, difference is returned
///
///      Oracle safety checks (in PriceConverter):
///        1. Staleness   — price not updated within 1 hour
///        2. Negative    — answer <= 0 indicates feed malfunction
///        3. Stale round — answeredInRound < roundId means stale data
///        4. Decimals    — dynamically normalized to 18 regardless of feed decimals
contract TeaShop is Ownable {

    ////////////////////////
    ////    ERRORS      ////
    ////////////////////////

    /// @notice Thrown when the price feed address provided to the constructor is zero
    error TeaShop_InvalidPriceFeed();

    /// @notice Thrown when msg.value is less than the ETH required to buy the item
    error TeaShop_NotSufficient();

    /// @notice Thrown when the item ID does not exist or the item has been deleted
    error TeaShop_ItemNotAvailable();

    /// @notice Thrown when an ETH transfer (refund, withdraw, or transferTo) fails
    error TeaShop_TransactionFailed();

    /// @notice Thrown when a price of zero is passed to addItem or updatePrice
    error TeaShop_InvalidPrice();

    /// @notice Thrown when a withdrawal or transfer amount exceeds the contract balance
    error TeaShop_InSufficientBalance();

    /// @notice Thrown when address(0) is passed as the recipient in transferTo
    error TeaShop_InvalidReceiver();

    ////////////////////////
    ////    TYPES       ////
    ////////////////////////

    /// @notice Represents a menu item in the shop
    /// @param name     Display name of the item
    /// @param price    Price in USD with 18 decimal precision (e.g. $5 = 5e18)
    /// @param available Whether the item is available for purchase (false = soft deleted)
    struct Item {
        string name;
        uint256 price;
        bool available;
    }

    ////////////////////////
    //// STATE VARIABLES ///
    ////////////////////////

    /// @dev Counter that also serves as the next item ID. Incremented on each addItem call.
    uint256 private itemId;

    /// @dev Tracks ETH held in the contract from purchases (in wei).
    ///      Decremented on withdraw and transferTo.
    uint256 private total_balance;

    /// @dev Decimal precision used when storing USD prices. Fixed at 18.
    uint256 private price_decimals = 18;

    /// @dev Maps item ID to Item struct
    mapping(uint256 => Item) private items;

    /// @dev Chainlink price feed interface, set once in constructor and immutable
    AggregatorV3Interface private immutable i_priceFeed;

    ////////////////////////
    ////    EVENTS      ////
    ////////////////////////

    /// @notice Emitted when a new item is added to the menu
    /// @param itemId  The ID assigned to the new item
    /// @param name    Display name of the item
    /// @param price   Price stored in USD with 18 decimals (e.g. $5 = 5e18)
    event NewItemAdded(uint256 indexed itemId, string name, uint256 price);

    /// @notice Emitted when an item's price is updated
    /// @param itemId   The ID of the updated item
    /// @param newPrice New price in USD with 18 decimals
    event PriceUpdated(uint256 indexed itemId, uint256 newPrice);

    /// @notice Emitted when an item is soft-deleted (marked unavailable)
    /// @param itemId The ID of the deleted item
    event MenuUpdated(uint256 indexed itemId);

    /// @notice Emitted when a successful purchase is made
    /// @param itemId The ID of the purchased item
    /// @param buyer  Address of the buyer
    event PurchaseMade(uint256 indexed itemId, address buyer);

    /// @notice Emitted when the owner withdraws ETH from the contract
    /// @param amount Amount withdrawn in wei
    event AmountWithdrawn(uint256 amount);

    /// @notice Emitted when the owner transfers ETH to a specific address
    /// @param to     Recipient address
    /// @param amount Amount transferred in wei
    event AmountTransfered(address indexed to, uint256 amount);

    ////////////////////////
    ////  CONSTRUCTOR   ////
    ////////////////////////

    /// @notice Deploys the TeaShop with a Chainlink price feed
    /// @dev Reverts if _priceFeed is the zero address
    /// @param _priceFeed Address of the Chainlink AggregatorV3Interface (ETH/USD)
    constructor(address _priceFeed) Ownable(msg.sender) {
        if (_priceFeed == address(0)) revert TeaShop_InvalidPriceFeed();
        i_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    ////////////////////////
    //// OWNER FUNCTIONS ///
    ////////////////////////

    /// @notice Adds a new item to the shop menu
    /// @dev Price is passed as a whole USD number (e.g. 5 = $5) and scaled to 18 decimals internally
    /// @param _name  Display name for the item
    /// @param price  Price in whole USD (e.g. 5 for $5). Must be greater than 0.
    function addItem(string memory _name, uint256 price) public onlyOwner {
        if (price == 0) revert TeaShop_InvalidPrice();
        uint256 usdPrice = price * 10 ** price_decimals;
        items[itemId++] = Item({name: _name, price: usdPrice, available: true});
        emit NewItemAdded(itemId - 1, _name, usdPrice);
    }

    /// @notice Updates the price of an existing menu item
    /// @dev Item must exist and be available. Price is scaled to 18 decimals internally.
    /// @param _itemId ID of the item to update
    /// @param price   New price in whole USD (e.g. 10 for $10). Must be greater than 0.
    function updatePrice(uint256 _itemId, uint256 price) public onlyOwner {
        if (_itemId >= itemId || items[_itemId].available == false) revert TeaShop_ItemNotAvailable();
        if (price == 0) revert TeaShop_InvalidPrice();
        uint256 usdPrice = price * 10 ** price_decimals;
        items[_itemId].price = usdPrice;
        emit PriceUpdated(_itemId, usdPrice);
    }

    /// @notice Soft-deletes an item by marking it unavailable
    /// @dev Does not clear storage. Item data remains but cannot be purchased or updated.
    /// @param _itemId ID of the item to delete
    function deleteItem(uint256 _itemId) public onlyOwner {
        if (_itemId >= itemId || items[_itemId].available == false) revert TeaShop_ItemNotAvailable();
        items[_itemId].available = false;
        emit MenuUpdated(_itemId);
    }

    /// @notice Withdraws ETH from the contract to the owner's address
    /// @dev Uses total_balance (tracked from purchases) not address(this).balance,
    ///      so ETH sent via receive/fallback is not included.
    /// @param amount Amount to withdraw in wei
    function withdraw(uint256 amount) public payable onlyOwner {
        if (amount > total_balance) revert TeaShop_InSufficientBalance();
        total_balance -= amount;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TeaShop_TransactionFailed();
        emit AmountWithdrawn(amount);
    }

    /// @notice Transfers ETH from the contract to a specified address
    /// @dev Useful for sending revenue to a treasury or partner address
    /// @param to     Recipient address. Cannot be address(0).
    /// @param amount Amount to transfer in wei
    function transferTo(address to, uint256 amount) public onlyOwner {
        if (amount > total_balance) revert TeaShop_InSufficientBalance();
        if (to == address(0)) revert TeaShop_InvalidReceiver();
        total_balance -= amount;
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert TeaShop_TransactionFailed();
        emit AmountTransfered(to, amount);
    }

    ////////////////////////
    //// PUBLIC FUNCTIONS //
    ////////////////////////

    /// @notice Purchase an item by sending ETH
    /// @dev The required ETH is calculated via getItemPriceInEth() using the live Chainlink feed.
    ///      Comparison is done in ETH (wei) to avoid round-trip USD→ETH→USD precision loss.
    ///      Any excess ETH sent is automatically refunded to the buyer.
    ///
    ///      Will revert if:
    ///        - The Chainlink price feed is stale (> 1 hour old)
    ///        - The feed returns a negative or zero price
    ///        - msg.value is less than getItemPriceInEth(_itemId)
    ///
    /// @param _itemId ID of the item to purchase
    function buyItem(uint256 _itemId) public payable {
        if (_itemId >= itemId || items[_itemId].available == false) revert TeaShop_ItemNotAvailable();
        if (msg.value < getItemPriceInEth(_itemId)) revert TeaShop_NotSufficient();
        uint256 excess = msg.value - getItemPriceInEth(_itemId);
        if (excess > 0) {
            (bool success,) = payable(msg.sender).call{value: excess}("");
            if (!success) revert TeaShop_TransactionFailed();
        }
        total_balance += msg.value;
        emit PurchaseMade(_itemId, msg.sender);
    }

    ////////////////////////
    ////  VIEW FUNCTIONS ///
    ////////////////////////

    /// @notice Returns the full details of a menu item
    /// @param _itemId ID of the item to query
    /// @return Item struct containing name, price (USD 18 dec), and availability
    function viewItemDetails(uint256 _itemId) public view returns (Item memory) {
        if (_itemId >= itemId) revert TeaShop_ItemNotAvailable();
        return (items[_itemId]);
    }

    /// @notice Returns the current ETH price of an item using the live Chainlink feed
    /// @dev Converts the stored USD price (18 dec) to wei using:
    ///        ethRequired = (usdPrice * 1e18) / ethPriceInUsd
    ///      Integer division truncates, so the result may be 1 wei less than exact.
    ///      Callers should add 1 wei when using this to fund a buyItem call.
    ///      Will revert if the price feed is stale, negative, or from a stale round.
    /// @param _itemId ID of the item to price
    /// @return ETH price of the item in wei
    function getItemPriceInEth(uint256 _itemId) public view returns (uint256) {
        if (_itemId >= itemId) revert TeaShop_ItemNotAvailable();
        uint256 usdPrice = items[_itemId].price;
        uint256 ethPriceInUsd = PriceConverter.getPrice(i_priceFeed);
        return (usdPrice * 1e18) / ethPriceInUsd;
    }

    /// @notice Returns the total number of items ever added (including deleted ones)
    /// @dev Use viewItemDetails to check if an item is still available
    /// @return Total item count
    function itemCount() public view returns (uint256) {
        return itemId;
    }

    ////////////////////////
    //// FALLBACK        ///
    ////////////////////////

    /// @notice Accepts direct ETH transfers (not tracked in total_balance)
    receive() external payable {}

    /// @notice Fallback for calls with calldata that don't match any function
    fallback() external payable {}
}
