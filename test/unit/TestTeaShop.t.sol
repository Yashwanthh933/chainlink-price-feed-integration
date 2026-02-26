//SPDX-License-Identifier:MIT
pragma solidity ^ 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployTeaShop} from "../../script/DeployTeaShop.s.sol";
import {TeaShop} from "../../src/TeaShop.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract CodeConstants {
    event NewItemAdded(uint256 indexed, string, uint256);
    event PriceUpdated(uint256 indexed, uint256);
    event MenuUpdated(uint256 indexed);
    event PurchaseMade(uint256 indexed, address);
    event AmountWithdrawn(uint256);
    event AmountTransfered(address indexed, uint256);
}

contract TestTeaShop is Test, CodeConstants {
    TeaShop private teaShop;
    //HelperConfig private helperConfig;
    DeployTeaShop private deployer;
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    uint256 private constant INITIAL_BALANCE = 10e18;
    address private priceFeed;

    function setUp() public {
        HelperConfig helperConfig = new HelperConfig();
        priceFeed = helperConfig.activeNetworkConfig();
        vm.startPrank(owner);
        teaShop = new TeaShop(priceFeed);
        vm.stopPrank();
        vm.deal(user1, INITIAL_BALANCE);
        vm.deal(user2, INITIAL_BALANCE);
    }

    function testOnlyOwnerCanAddItems() public {
        vm.startPrank(user1);
        string memory name = "bellam Tea";
        uint256 price = 1; // 1 USD
        vm.expectRevert();
        teaShop.addItem(name, price);
    }

    function testOwnerCanAddItem() public {
        vm.startPrank(owner);
        string memory name = "bellam tea";
        uint256 price = 1;
        uint256 itemCount = teaShop.itemCount();
        vm.assertEq(itemCount, 0);
        teaShop.addItem(name, price);
        vm.assertEq(itemCount + 1, teaShop.itemCount());
    }

    function testUpdatePrice() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 1;
        uint256 newPrice = 2;
        teaShop.addItem(name, price);
        teaShop.updatePrice(teaShop.itemCount() - 1, newPrice);
        TeaShop.Item memory updatedPrice = teaShop.viewItemDetails(teaShop.itemCount() - 1);
        vm.assertEq(newPrice * 10 ** 18, updatedPrice.price);
        vm.stopPrank();
    }

    function testUpdatePriceRevertsIfNotOwner() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 1;
        uint256 newPrice = 2;
        teaShop.addItem(name, price);
        vm.assertEq(1, teaShop.itemCount());
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(user1);
        teaShop.updatePrice(0, newPrice);
        TeaShop.Item memory item1 = teaShop.viewItemDetails(0);
        TeaShop.Item memory item2 = teaShop.viewItemDetails(teaShop.itemCount() - 1);
        console.log(item1.price);
        console.log(item2.price);
    }

    function testAddItemRevertsIfPriceIsZero() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 0;
        vm.expectRevert();
        teaShop.addItem(name, price);
    }

    function testUpdateItemRevertsIfPriceIsZero() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 1e18;
        uint256 newPrice = 0;
        teaShop.addItem(name, price);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(owner);
        teaShop.updatePrice(0, newPrice);
    }

    function testDeleteItem() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 1;
        teaShop.addItem(name, price);
        teaShop.deleteItem(0);
        vm.stopPrank();
        vm.assertEq(false, teaShop.viewItemDetails(0).available);
    }

    function testPriceFeedReturnsCorrectly() public {
        (, int256 answer,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        console.log(answer);
    }

    function testAddItemIncreaseTheSize() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 10; // 10 usd
        teaShop.addItem(name, price);
        vm.stopPrank();
        assertEq(teaShop.itemCount(), 1);
        assertEq(teaShop.viewItemDetails(0).price, price * 10 ** 18);
    }

    function testRevertsIfPriceIszero() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 0;
        vm.expectRevert();
        teaShop.addItem(name, price);
        vm.stopPrank();
    }

    function testAddItemEmitsItemAdded() public {
        vm.startPrank(owner);
        string memory name = "bellam Coffee";
        uint256 price = 1;
        vm.expectEmit(true, false, false, true);
        emit NewItemAdded(0, name, price * 10 ** 18);
        teaShop.addItem(name, price);
    }

    function testUpdatePriceEmitsPriceUpdated() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 1;
        uint256 newPrice = 2;
        teaShop.addItem(name, price);
        vm.expectEmit(true, false, false, true);
        emit PriceUpdated(0, 2 * 10 ** 18);
        teaShop.updatePrice(0, newPrice);
    }

    function testDeleteItemRevertsIfItemIdIsNotValid() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 1;
        teaShop.addItem(name, price);
        vm.expectRevert();
        teaShop.deleteItem(1);
    }

    function testBuyItemRevertsIfItemIsNotAvailable() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 1;
        teaShop.addItem(name, price);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(user1);
        teaShop.buyItem{value: 0.5e18}(1);
    }

    function testBuyItemIncreasesContractBalance() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 1;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 ethPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: ethPrice}(0);
        assertEq(address(teaShop).balance, ethPrice);
        vm.prank(user2);
        teaShop.buyItem{value: ethPrice}(0);
        assertEq(address(teaShop).balance, 2 * ethPrice);
    }

    function testBuyItemRevertsIfItemIsDeleted() public {
        vm.startPrank(owner);
        string memory name = "bellam coffe";
        uint256 price = 10;
        teaShop.addItem(name, price);
        teaShop.deleteItem(0);
        vm.stopPrank();
        uint256 ethPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        vm.expectRevert();
        teaShop.buyItem{value: ethPrice}(0);
    }

    function testBuyItemRefundsIfUserPayExcess() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 2000;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 balanceBefore = user1.balance;
        uint256 itemPriceInEth = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: 2e18}(0);
        uint256 balanceAfter = user1.balance;
        assertEq(balanceAfter, balanceBefore - 2e18 + itemPriceInEth);
    }

    function testWithdrawFailsIfNonOwnerCalls() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(user1);
        vm.expectRevert();
        teaShop.withdraw(itemEthPrice);
    }

    function testWithdrawFailsIfOwnerTriesWithdrawExcessAmount() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(owner);
        vm.expectRevert();
        teaShop.withdraw(itemEthPrice + 1);
    }

    function testWithdrawEmitsAmountWithDrawn() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AmountWithdrawn(itemEthPrice);
        teaShop.withdraw(itemEthPrice);
    }

    function testTransferFailsIfNonOwnerTries() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(user1);
        vm.expectRevert();
        teaShop.transferTo(user1, itemEthPrice);
    }

    function testTransferFailsIfOwnerTriesToSentExtra() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(owner);
        vm.expectRevert();
        teaShop.transferTo(user1, itemEthPrice + 1);
    }

    function testTransferEmitsEvent() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AmountTransfered(user1, itemEthPrice);
        teaShop.transferTo(user1, itemEthPrice);
    }

    function testTransferUpdatesTheToAddressBalance() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 20;
        teaShop.addItem(name, price);
        vm.stopPrank();
        uint256 itemEthPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        teaShop.buyItem{value: itemEthPrice}(0);
        uint256 userBalanceBefore = user1.balance;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AmountTransfered(user1, itemEthPrice);
        teaShop.transferTo(user1, itemEthPrice);
        assertEq(user1.balance, userBalanceBefore + itemEthPrice);
    }

    function testBuyTimeRevertsWithNegativePrice() public {
        vm.startPrank(owner);
        string memory name = "bellam coffee";
        uint256 price = 1;
        teaShop.addItem(name, price);
        vm.stopPrank();
        MockV3Aggregator(priceFeed).updateAnswer(-10);
        vm.expectRevert();
        uint256 ethPrice = teaShop.getItemPriceInEth(0);
        vm.prank(user1);
        vm.expectRevert();
        teaShop.buyItem{value: ethPrice}(0);
    }
    // function testBuyitemRevertsIfPriceFeedIsAccurate() public{
    //     vm.startPrank(owner);
    //     string memory name = "bellam coffee";
    //     uint256 price = 1;
    //     teaShop.addItem(name,price);
    //     vm.stopPrank();
    //     vm.expectRevert();
    //     uint256 ethPrice = teaShop.getItemPriceInEth(0);
    //     vm.prank(user1);
    //     vm.expectRevert();
    //     teaShop.buyItem{value:ethPrice}(0);
    // }
}
