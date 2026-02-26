// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {TeaShop} from "../../src/TeaShop.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "../../src/PriceConverter.sol";

/**
 * @title TestTeaShopFork
 * @notice Integration tests against real Chainlink ETH/USD feed on Sepolia
 * @dev Run with: forge test --match-path test/integration/* --fork-url $SEPOLIA_RPC_URL -vvvv
 *      or if alias is set in foundry.toml: forge test --match-path test/integration/* -vvvv
 *
 * These tests are intentionally minimal — they only test what REQUIRES a real feed.
 * Business logic (addItem, deleteItem, ownership etc) is already covered in unit tests.
 *
 * What we test here:
 * 1. Real feed returns a valid, sane price
 * 2. Decimal normalization works correctly with the real feed
 * 3. Staleness check triggers correctly (via vm.warp)
 * 4. buyItem works end-to-end with live price
 * 5. Refund logic works correctly with live price
 * 6. getItemPriceInEth returns a sane ETH amount
 */
/**
 * @notice Helper contract that can receive ETH
 * @dev makeAddr() creates plain addresses that cannot receive ETH via .call in fork mode
 *      This contract is used as the buyer in refund tests where ETH needs to be returned
 */
contract ETHReceiver {
    receive() external payable {}
}

contract TestTeaShopFork is Test {
    ///////////////////////
    /// STATE VARIABLES ///
    ///////////////////////

    TeaShop private teaShop;
    AggregatorV3Interface private priceFeed;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    // Sepolia ETH/USD feed address — same as HelperConfig
    address constant SEPOLIA_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    // Chainlink ETH/USD heartbeat on Sepolia is 1 hour
    uint256 constant HEARTBEAT = 1 hours;

    // Price sanity bounds — ETH should be between $100 and $100,000
    int256 constant MIN_EXPECTED_PRICE = 100e8; // $100 in 8 decimals
    int256 constant MAX_EXPECTED_PRICE = 100_000e8; // $100,000 in 8 decimals

    ///////////////////////
    ///    SETUP        ///
    ///////////////////////

    function setUp() public {
        // fork Sepolia at latest block — gets fresh live price every run
        // uses "sepolia" alias defined in foundry.toml which reads from .env
        vm.createSelectFork("sepolia");

        priceFeed = AggregatorV3Interface(SEPOLIA_PRICE_FEED);

        vm.prank(owner);
        teaShop = new TeaShop(SEPOLIA_PRICE_FEED);

        // give users enough ETH to buy items
        // 5 ETH is more than enough for any realistic item price
        vm.deal(user1, 5 ether);
        vm.deal(user2, 5 ether);
    }

    ////////////////////////////////
    /// FEED VALIDATION TESTS    ///
    ////////////////////////////////

    /**
     * @notice Verifies the real Chainlink feed is alive and returning sane values
     * @dev This is the most fundamental fork test — if this fails, something is
     *      seriously wrong with either the feed or your RPC connection
     */
    function testFork_PriceFeedReturnsValidPrice() public {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        console.log("=== Live Chainlink Feed Data ===");
        console.log("Round ID         :", roundId);
        console.log("ETH/USD price    :", uint256(answer)); // e.g. 324758000000 = $3247.58
        console.log("Started at       :", startedAt);
        console.log("Updated at       :", updatedAt);
        console.log("Answered in round:", answeredInRound);
        console.log("Feed decimals    :", priceFeed.decimals()); // should be 8
        console.log("================================");

        // price must be positive
        assertGt(answer, 0, "Price should be positive");

        // price should be within realistic ETH range
        assertGt(answer, MIN_EXPECTED_PRICE, "Price below minimum expected");
        assertLt(answer, MAX_EXPECTED_PRICE, "Price above maximum expected");

        // round data must be complete
        assertGt(startedAt, 0, "Round never started");
        assertGt(updatedAt, 0, "Round never updated");

        // answeredInRound must be >= roundId (stale round check)
        assertGe(answeredInRound, roundId, "Answer from a previous round");

        // feed must be fresh — updated within the last heartbeat window
        assertLt(block.timestamp - updatedAt, HEARTBEAT);
    }

    /**
     * @notice Verifies feed has 8 decimals as expected
     * @dev If Chainlink ever changes decimals, our normalization logic breaks
     *      This test acts as an early warning system
     */
    function testFork_FeedHasCorrectDecimals() public {
        uint8 decimals = priceFeed.decimals();
        console.log("Feed decimals:", decimals);

        // ETH/USD feed is always 8 decimals
        assertEq(decimals, 8, "Expected 8 decimals from ETH/USD feed");
    }

    ///////////////////////////////////
    /// DECIMAL NORMALIZATION TESTS ///
    ///////////////////////////////////

    /**
     * @notice Verifies PriceConverter correctly normalizes 8-decimal feed to 18 decimals
     * @dev Core of the decimal handling learning goal
     *      Raw feed: answer = e.g. 324758000000 (8 decimals = $3247.58)
     *      Normalized: should be 3247580000000000000000 (18 decimals)
     */
    function testFork_DecimalNormalizationIsCorrect() public {
        (, int256 rawAnswer,,,) = priceFeed.latestRoundData();
        uint8 feedDecimals = priceFeed.decimals(); // 8

        // manually compute what normalized price should be
        uint256 expectedNormalized = uint256(rawAnswer) * 10 ** (18 - feedDecimals);

        // get what PriceConverter actually returns
        uint256 actualNormalized = PriceConverter.getPrice(priceFeed);

        console.log("Raw answer (8 dec)  :", uint256(rawAnswer));
        console.log("Expected (18 dec)   :", expectedNormalized);
        console.log("Actual (18 dec)     :", actualNormalized);

        assertEq(actualNormalized, expectedNormalized);

        // normalized price should be in a realistic range (18 decimals)
        // $100 to $100,000 expressed with 18 decimals
        assertGt(actualNormalized, 100e18, "Normalized price too low");
        assertLt(actualNormalized, 100_000e18, "Normalized price too high");
    }

    /**
     * @notice Verifies getItemPriceInEth returns a realistic ETH amount
     * @dev For a $1 item at ~$3000/ETH, we expect roughly 0.000333 ETH
     *      This test ensures the USD→ETH conversion math is correct
     */
    function testFork_GetItemPriceInEthReturnsRealisticValue() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1); // $1 item

        uint256 itemPriceInEth = teaShop.getItemPriceInEth(0);

        console.log("Item price in ETH (wei):", itemPriceInEth);
        console.log("Item price in ETH      :", itemPriceInEth / 1e14, "* 0.0001 ETH");

        // for a $1 item, price should be between 0.000001 ETH and 0.1 ETH
        // this range covers ETH prices from $10 to $1,000,000
        assertGt(itemPriceInEth, 1e12);
        assertLt(itemPriceInEth, 0.1 ether);
    }

    ///////////////////////////////
    /// ORACLE SAFETY TESTS     ///
    ///////////////////////////////

    /**
     * @notice Verifies staleness check triggers when feed is older than 1 hour
     * @dev vm.warp simulates time passing — feed updatedAt stays the same
     *      but block.timestamp advances, making the price appear stale
     */
    function testFork_StalePriceRevertsOnBuyItem() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1); // $1

        // calculate ETH needed before warping (feed is still fresh)
        uint256 ethNeeded = teaShop.getItemPriceInEth(0);

        // warp 2 hours into the future — feed becomes stale
        // feed updatedAt doesn't change but block.timestamp does
        vm.warp(block.timestamp + 2 hours);

        console.log("Warped block.timestamp by 2 hours");
        console.log("Feed should now appear stale");

        vm.expectRevert(PriceConverter.StalePrice.selector);
        vm.prank(user1);
        teaShop.buyItem{value: ethNeeded}(0);
    }

    /**
     * @notice Verifies staleness check triggers on getItemPriceInEth too
     * @dev getItemPriceInEth internally calls PriceConverter.getPrice
     *      so it should also revert when feed is stale
     */
    function testFork_StalePriceRevertsOnGetItemPriceInEth() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1);

        // warp past the staleness threshold
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(PriceConverter.StalePrice.selector);
        teaShop.getItemPriceInEth(0);
    }

    ///////////////////////////////
    /// END TO END TESTS        ///
    ///////////////////////////////

    /**
     * @notice Full buyItem flow using live Chainlink price
     * @dev This is the key integration test — proves your contract works
     *      end-to-end with a real oracle, not just a mock
     *
     *      Key difference from unit test:
     *      - Price is read dynamically from Chainlink, not hardcoded
     *      - We add a buffer to account for minor price movements
     */
    function testFork_BuyItemSucceedsWithLivePrice() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1);

        ETHReceiver buyer = new ETHReceiver();
        vm.deal(address(buyer), 5 ether);

        // +1 wei covers integer division truncation in getItemPriceInEth
        uint256 itemPriceInEth = teaShop.getItemPriceInEth(0) + 1;

        console.log("Item price in ETH (+1 wei):", itemPriceInEth);

        uint256 contractBalanceBefore = address(teaShop).balance;

        vm.prank(address(buyer));
        teaShop.buyItem{value: itemPriceInEth}(0);

        assertGt(address(teaShop).balance, contractBalanceBefore);
    }

    /**
     * @notice Verifies buyItem refunds excess ETH with live price
     * @dev Sends 2x the required ETH — user should get the difference back
     *      This tests that the unit mismatch bug is fixed:
     *      excess = msg.value(wei) - getItemPriceInEth(wei) ✅
     *      NOT: msg.value(wei) - item.price(usd) ❌
     */
    function testFork_BuyItemRefundsExcessWithLivePrice() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1); // $1 item

        // use ETHReceiver contract as buyer — not makeAddr()
        // reason: the refund sends ETH back via .call
        //         makeAddr() addresses have no receive() so .call reverts in fork mode
        //         ETHReceiver has receive() so it accepts the refund correctly
        ETHReceiver buyer = new ETHReceiver();
        vm.deal(address(buyer), 5 ether);

        uint256 itemPriceInEth = teaShop.getItemPriceInEth(0);

        // send 2x the required ETH — excess should be refunded
        uint256 ethToSend = itemPriceInEth * 2;
        uint256 balanceBefore = address(buyer).balance;

        vm.prank(address(buyer));
        teaShop.buyItem{value: ethToSend}(0);

        uint256 actualSpent = balanceBefore - address(buyer).balance;

        console.log("Item price in ETH :", itemPriceInEth);
        console.log("ETH sent (2x)     :", ethToSend);
        console.log("Actual spent      :", actualSpent);

        // buyer should have spent approximately itemPriceInEth, not ethToSend
        // tiny tolerance for integer division rounding in getItemPriceInEth
        assertApproxEqAbs(actualSpent, itemPriceInEth, 1e10);
    }

    /**
     * @notice Verifies buyItem reverts if not enough ETH sent
     * @dev Sends only 10% of required ETH — should revert with NotSufficient
     */
    function testFork_BuyItemRevertsIfInsufficientEth() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1); // $1 item

        uint256 itemPriceInEth = teaShop.getItemPriceInEth(0);

        // send only 10% of required ETH — should definitely fail
        uint256 insufficientEth = itemPriceInEth / 10;

        console.log("Required ETH :", itemPriceInEth);
        console.log("Sending ETH  :", insufficientEth);

        vm.expectRevert(TeaShop.TeaShop_NotSufficient.selector);
        vm.prank(user1);
        teaShop.buyItem{value: insufficientEth}(0);
    }

    /**
     * @notice Multiple users buy the same item — balance accumulates correctly
     */
    function testFork_MultipleUsersBuyItemBalanceAccumulates() public {
        vm.prank(owner);
        teaShop.addItem("bellam coffee", 1);

        // both users need to be ETHReceiver — +1 wei creates 1 wei excess
        // that 1 wei gets refunded back, so buyer needs receive()
        ETHReceiver buyer1 = new ETHReceiver();
        ETHReceiver buyer2 = new ETHReceiver();
        vm.deal(address(buyer1), 5 ether);
        vm.deal(address(buyer2), 5 ether);

        uint256 ethToSend = teaShop.getItemPriceInEth(0) + 1;

        console.log("ETH sent (+1 wei):", ethToSend);

        vm.prank(address(buyer1));
        teaShop.buyItem{value: ethToSend}(0);

        vm.prank(address(buyer2));
        teaShop.buyItem{value: ethToSend}(0);

        console.log("Contract balance :", address(teaShop).balance);

        assertGt(address(teaShop).balance, 0);
    }
}
