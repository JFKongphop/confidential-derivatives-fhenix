// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title PricingEngine - Option premium and settlement calculations
/// @notice Black-Scholes approximation (IV = 20%, RFR = 5%, T = 7 days) — suitable for MVP.
///         Futures P&L is computed inline in PerpetualFutures.sol using plaintext price
///         deltas applied to encrypted sizes — no library call needed there.
///
/// Decimal conventions:
///   • Prices  : 8 decimals  (Chainlink, e.g. $2 000 → 200_000_000_00)
///   • Premiums: 8 decimals  (same as price domain)
///   • Sizes   : 6 decimals  (USDC)
library PricingEngine {
  uint256 public constant BPS_DENOMINATOR = 10_000;

  // ── Options (public — no encrypted inputs needed for premium) ────────────

  /// @notice Simplified Black-Scholes premium for a CALL option.
  ///         IV = 20%, RFR = 5%, T = 7 days (hardcoded for MVP).
  ///         Returns premium in same decimal units as spotPrice.
  /// @param  spotPrice   Current market price (8 decimals)
  /// @param  strikePrice Strike price         (8 decimals)
  /// @return premium     Estimated call premium (8 decimals)
  function blackScholesCall(
    uint256 spotPrice, 
    uint256 strikePrice
  ) internal pure returns (uint256 premium) {
    // Extrinsic value ≈ 4% of spot (approximation for 7-day, 20% IV)
    uint256 extrinsic = (spotPrice * 400) / BPS_DENOMINATOR; // 4% = 400 bps

    if (spotPrice >= strikePrice) {
      // ITM or ATM: intrinsic + extrinsic
      uint256 intrinsic = spotPrice - strikePrice;
      premium = intrinsic + extrinsic;
    } else {
      // OTM: extrinsic - out-of-moneyness (floor at 0)
      uint256 otm = strikePrice - spotPrice;
      premium = extrinsic > otm ? extrinsic - otm : 0;
    }
  }

  /// @notice Simplified Black-Scholes premium for a PUT option.
  /// @param  spotPrice   Current market price (8 decimals)
  /// @param  strikePrice Strike price         (8 decimals)
  /// @return premium     Estimated put premium (8 decimals)
  function blackScholesPut(
    uint256 spotPrice, 
    uint256 strikePrice
  ) internal pure returns (uint256 premium) {
    uint256 extrinsic = (spotPrice * 400) / BPS_DENOMINATOR; // 4%

    if (strikePrice >= spotPrice) {
      // ITM or ATM
      uint256 intrinsic = strikePrice - spotPrice;
      premium = intrinsic + extrinsic;
    } else {
      uint256 otm = spotPrice - strikePrice;
      premium = extrinsic > otm ? extrinsic - otm : 0;
    }
  }

  /// @notice Compute settlement value of an option at exercise.
  /// @param  currentPrice Current market price (8 decimals)
  /// @param  strikePrice  Strike price         (8 decimals)
  /// @param  isCall       true = call, false = put
  /// @return value        Settlement value (8 decimals); 0 if OTM
  function getOptionValue(
    uint256 currentPrice, 
    uint256 strikePrice, 
    bool isCall
  ) internal pure returns (uint256 value) {
    if (isCall) {
      value = currentPrice > strikePrice ? currentPrice - strikePrice : 0;
    } else {
      value = strikePrice > currentPrice ? strikePrice - currentPrice : 0;
    }
  }
}
