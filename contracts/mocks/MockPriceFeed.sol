// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title MockPriceFeed - Chainlink AggregatorV3 mock for testing
contract MockPriceFeed {
  int256 private _price;
  uint80 private _roundId;
  uint256 private _updatedAt;
  uint8 public constant decimals = 8;

  event PriceSet(int256 newPrice);

  constructor(int256 initialPrice) {
    _price = initialPrice;
    _roundId = 1;
    _updatedAt = block.timestamp;
  }

  /// @notice Set a new mock price (owner only in production, public for tests)
  function setPrice(int256 newPrice) external {
    _price = newPrice;
    _roundId++;
    _updatedAt = block.timestamp;
    emit PriceSet(newPrice);
  }

  function setUpdatedAt(uint256 timestamp) external {
    _updatedAt = timestamp;
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
  }

  function getRoundData(uint80 requestedRoundId)
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (requestedRoundId, _price, _updatedAt, _updatedAt, requestedRoundId);
  }
}
