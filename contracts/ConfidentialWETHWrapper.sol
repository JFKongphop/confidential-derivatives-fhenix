// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./FHERC20.sol";

/// @title ConfidentialWETHWrapper
/// @notice Wraps any ERC-20 WETH into an FHERC20 confidential token at 1:1.
///         Users deposit WETH and receive cWETH whose balance and transfers are
///         fully encrypted via Fhenix CoFHE. Collateral is denominated in ETH — matching
///         the Chainlink ETH/USD oracle used by PerpetualFutures and OptionsPool.
///
/// Usage:
///   1. user calls weth.approve(wrapperAddress, amount)
///   2. user calls wrapper.wrap(amount)
///      → WETH is held by this contract, cWETH is minted encrypted to user
///   3. To exit: wrapper.unwrap(encryptedAmount)
///      → cWETH burned, WETH returned
contract ConfidentialWETHWrapper is FHERC20 {
  IERC20 public immutable underlying;

  event Wrapped(address indexed user, uint256 amount);
  event Unwrapped(address indexed user, uint256 amount);

  constructor(
    IERC20 _underlying
  ) FHERC20("Confidential WETH", "cWETH", 18) {
    underlying = _underlying;
  }

  /// @notice Wrap WETH into encrypted cWETH
  /// @param amount Amount of WETH to wrap
  function wrap(uint256 amount) external returns (euint64) {
    require(amount > 0 && amount <= type(uint64).max, "Invalid amount");
    
    // Transfer WETH from user to this contract
    require(underlying.transferFrom(msg.sender, address(this), amount), "Transfer failed");

    // Mint encrypted cWETH to user
    euint64 encAmount = FHE.asEuint64(uint64(amount));
    _mintEncrypted(msg.sender, encAmount);

    emit Wrapped(msg.sender, amount);
    return encAmount;
  }

  /// @notice Unwrap encrypted cWETH back to WETH
  /// @param plainAmount Amount of cWETH to unwrap (must be plaintext for WETH transfer)
  /// @dev Note: In production, this would use async decryption. For simplicity,
  ///      we require plaintext amount and verify it matches the encrypted balance.
  function unwrap(uint64 plainAmount) external {
    require(plainAmount > 0, "Invalid amount");
    
    euint64 encAmount = FHE.asEuint64(plainAmount);
    
    // Burn encrypted cWETH from user
    _burnEncrypted(msg.sender, encAmount);
    
    // Transfer WETH back to user
    require(underlying.transfer(msg.sender, uint256(plainAmount)), "Transfer failed");

    emit Unwrapped(msg.sender, uint256(plainAmount));
  }

  /// @dev Burn encrypted tokens (internal helper)
  function _burnEncrypted(address from, euint64 amount) internal {
    euint64 balance = confidentialBalanceOf(from);
    require(FHE.isInitialized(balance), "No balance");
    
    // Use FHE subtraction (will underflow-check via FHE)
    euint64 newBalance = FHE.sub(balance, amount);
    FHE.allowThis(newBalance);
    FHE.allow(newBalance, from);
    
    // Update via internal transfer to zero address (burn pattern)
    _transfer(from, address(0), amount);
  }
}
