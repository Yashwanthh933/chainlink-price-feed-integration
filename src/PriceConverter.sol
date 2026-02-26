//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter {
    error StalePrice();
    error InvalidPrice();
    error StaleRound();

    /// @notice Fetches the current ETH/USD price from Chainlink and normalizes it to 18 decimals
    /// @dev Performs all 3 oracle safety checks before returning the price:
    ///        - Staleness:   block.timestamp - updatedAt > 1 hours
    ///        - Negative:    answer < 0
    ///        - Stale round: answeredInRound < roundId
    ///
    ///      Decimal normalization logic:
    ///        feedDecimals < 18 → multiply up   (most feeds including ETH/USD = 8 dec)
    ///        feedDecimals > 18 → divide down   (rare, but handled defensively)
    ///        feedDecimals == 18 → return as-is
    ///
    /// @param priceFeed Chainlink AggregatorV3Interface for ETH/USD
    /// @return ETH price in USD with 18 decimal precision (e.g. $2000 = 2000e18)
    
    function getPrice(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) revert StalePrice();
        if (answer < 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StaleRound();
        uint256 feedDecimals = priceFeed.decimals();
        uint256 targetDecimals = 18;
        if (feedDecimals < targetDecimals) {
            return (uint256(answer) * 10 ** (targetDecimals - feedDecimals));
        } else if (feedDecimals > targetDecimals) {
            return (uint256(answer) * 10 ** (feedDecimals - targetDecimals));
        } else {
            return uint256(answer);
        }
    }
    /// @notice Converts a given ETH amount (in wei) to its USD equivalent (18 decimal precision)
    /// @dev Formula: (ethPriceUsd * ethAmount) / 1e18
    ///      Division by 1e18 cancels out the extra 18 decimals introduced by multiplying
    ///      two 18-decimal values together:
    ///        ethPrice (18 dec) × ethAmount (18 dec) = 36 decimals
    ///        ÷ 1e18 → back to 18 decimals ✅
    ///
    /// @param ethAmount  ETH amount in wei (e.g. 0.5 ETH = 5e17)
    /// @param priceFeed  Chainlink AggregatorV3Interface for ETH/USD
    /// @return USD value of the ETH amount with 18 decimal precision (e.g. $1000 = 1000e18)

    function getConversionRate(uint256 ethAmount, AggregatorV3Interface priceFeed) internal view returns (uint256) {
        uint256 ethPrice = getPrice(priceFeed);
        uint256 ethAmountInUsd = (ethPrice * ethAmount) / 1000000000000000000;
        return ethAmountInUsd;
    }
}
