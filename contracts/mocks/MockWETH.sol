// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWETH - Faucet ERC-20 for testing ConfidentialWETHWrapper
/// @notice Anyone can call faucet() to receive test WETH. 18 decimals like real WETH.
contract MockWETH is ERC20 {
  uint256 public constant FAUCET_AMOUNT = 10 ether; // 10 WETH

  constructor() ERC20("Mock WETH", "WETH") {}

  /// @notice Get 10 test WETH. Can be called by anyone, anytime.
  function faucet() external {
    _mint(msg.sender, FAUCET_AMOUNT);
  }

  /// @notice Direct mint for deploy scripts / tests.
  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}
