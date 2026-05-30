// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "../FHERC20.sol";

/// @title MockConfidentialToken - FHERC20 confidential token for testing
/// @notice Provides a public mint function so tests can fund wallets without
///         an encrypted input. All balances and transfers are encrypted via Fhenix CoFHE.
contract MockConfidentialToken is FHERC20 {
  constructor() FHERC20("Mock Confidential WETH", "cWETH", 18) {}

  /// @notice Mint `amount` tokens to `to`. Test helper only.
  function mint(address to, uint64 amount) external {
    _mintEncrypted(to, FHE.asEuint64(amount));
  }
}
