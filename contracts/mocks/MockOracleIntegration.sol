// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../OracleIntegration.sol";

/// @title MockOracleIntegration - Testable OracleIntegration with configurable feed
/// @dev Overrides the hardcoded FEED_ADDRESS so tests can inject a MockPriceFeed.
contract MockOracleIntegration {
  AggregatorV3Interface public immutable priceFeed;
  uint256 public constant STALENESS_THRESHOLD = 1 hours;

  constructor(address feedAddress) {
    priceFeed = AggregatorV3Interface(feedAddress);
  }

  function getCurrentPrice() external view returns (uint256) {
    (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
    require(price > 0, "Invalid price");
    require(block.timestamp - updatedAt < STALENESS_THRESHOLD, "Price feed stale");
    return uint256(price);
  }

  function getPriceAtRound(uint80 roundId) external view returns (uint256) {
    (, int256 price,,,) = priceFeed.getRoundData(roundId);
    require(price > 0, "Invalid price");
    return uint256(price);
  }
}
