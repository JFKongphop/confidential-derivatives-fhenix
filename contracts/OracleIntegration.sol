// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function getRoundData(uint80 _roundId)
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title OracleIntegration - Chainlink ETH/USD price feed wrapper
/// @notice Returns prices with 8-decimal precision (Chainlink default).
///         All consuming contracts use this to obtain the current mark price.
contract OracleIntegration {
  /// @dev Chainlink ETH/USD feed on Sepolia
  address public constant FEED_ADDRESS = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

  AggregatorV3Interface public immutable priceFeed;

  /// @dev Maximum age (seconds) before a price is considered stale
  uint256 public constant STALENESS_THRESHOLD = 1 hours;

  event PriceFeedUpdated(address newFeed);

  constructor() {
    priceFeed = AggregatorV3Interface(FEED_ADDRESS);
  }

  /// @notice Returns the latest ETH/USD price with 8-decimal precision.
  ///         Reverts if the price is stale or invalid.
  function getCurrentPrice() external view returns (uint256) {
    (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
    require(price > 0, "Invalid price");
    require(block.timestamp - updatedAt < STALENESS_THRESHOLD, "Price feed stale");
    return uint256(price);
  }

  /// @notice Returns the price recorded at a specific Chainlink round.
  /// @param  roundId The Chainlink round identifier
  function getPriceAtRound(uint80 roundId) external view returns (uint256) {
    (, int256 price,,,) = priceFeed.getRoundData(roundId);
    require(price > 0, "Invalid price");
    return uint256(price);
  }
}
