// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "./FHERC20.sol";
import "./interfaces/IERC7984Receiver.sol";

/// @title Collateral - Encrypted collateral vault for Futures and Options
/// @notice Users deposit FHERC20 confidential tokens; balances are stored encrypted
///         using Fhenix CoFHE. Withdrawals are fully synchronous — no oracle round-trip needed.
///
/// Deposit flow:
///   1. User calls token.confidentialTransferAndCall(collateralAddr, encryptedAmount, "").
///   2. Token verifies and calls onConfidentialTransferReceived.
///
/// Withdraw flow (no oracle):
///   1. User calls withdraw(encryptedAmount) — FHE.select clamps to available balance.
///   2. Token transfer happens in the same transaction.
contract Collateral is IERC7984Receiver {
  // ── State ────────────────────────────────────────────────────────────────

  FHERC20 public immutable token;
  address public immutable owner;

  /// @dev Per-user encrypted balance (euint64 — fits up to ~18.4e18 wei)
  mapping(address => euint64) internal _collateral;
  mapping(address => bool) public authorised;

  // ── Events ───────────────────────────────────────────────────────────────

  /// @dev Handle emitted so the permitted user can decrypt their own history.
  ///      Only ACL-permitted addresses can decrypt the handle — onlookers cannot.
  event Deposit(address indexed user, bytes32 amount);
  event Withdraw(address indexed user, bytes32 amount);

  // ── Constructor ──────────────────────────────────────────────────────────

  constructor(address tokenAddress) {
    token = FHERC20(tokenAddress);
    owner = msg.sender;
  }

  // ── External functions ───────────────────────────────────────────────────

  /// @notice FHERC20 receiver callback — called by the token after a confidentialTransferAndCall.
  ///         User calls token.confidentialTransferAndCall(collateral, encryptedAmount, "") directly.
  /// @param  operator The address which initiated the transfer
  /// @param  from    The sender of the confidential transfer (user).
  /// @param  encryptedAmount  Already-verified encrypted amount.
  /// @param  data    Additional data (unused)
  function onConfidentialTransferReceived(
    address operator,
    address from,
    bytes32 encryptedAmount,
    bytes calldata data
  ) external override returns (bytes4) {
    require(msg.sender == address(token), "Collateral: only token");

    euint64 amount = euint64.wrap(encryptedAmount);

    if (FHE.isInitialized(_collateral[from])) {
      _collateral[from] = FHE.add(_collateral[from], amount);
    } else {
      _collateral[from] = amount;
    }

    FHE.allowThis(_collateral[from]);
    FHE.allow(_collateral[from], from);
    FHE.allow(amount, from);

    emit Deposit(from, encryptedAmount);
    
    return IERC7984Receiver.onConfidentialTransferReceived.selector;
  }

  /// @notice Withdraw up to `encAmount` tokens from the vault in a single transaction.
  ///         If the encrypted balance is less than the requested amount, the entire balance
  ///         is returned (FHE.select clamp) — no revert, no oracle. The withdrawal amount
  ///         remains confidential because it is supplied as an encrypted input.
  /// @param  encAmount  Off-chain encrypted amount (InEuint64).
  function withdraw(InEuint64 memory encAmount) external {
    euint64 requested = FHE.asEuint64(encAmount);
    
    // actual = min(_collateral, requested) — fully encrypted, never revealed
    ebool hasEnough = FHE.gte(_collateral[msg.sender], requested);
    euint64 actual = FHE.select(hasEnough, requested, _collateral[msg.sender]);

    _collateral[msg.sender] = FHE.sub(_collateral[msg.sender], actual);
    FHE.allowThis(_collateral[msg.sender]);
    FHE.allow(_collateral[msg.sender], msg.sender);
    // Allow the user to decrypt the emitted handle from the event log.
    FHE.allow(actual, msg.sender);

    // Grant the FHERC20 token transient ACL access to process the transfer amount.
    FHE.allowThis(actual);
    FHE.allow(actual, address(token));
    token.confidentialTransfer(msg.sender, actual);

    emit Withdraw(msg.sender, FHE.unwrap(actual));
  }

  /// @notice Returns the encrypted balance handle for `msg.sender`.
  ///         Decrypt client-side with fhenix SDK.
  function getMyCollateral() external view returns (euint64) {
    return _collateral[msg.sender];
  }

  // ── Access control for protocol contracts ─────────────────────────────────
  modifier onlyAuthorised() {
    require(authorised[msg.sender] || msg.sender == owner, "Not authorised");
    _;
  }

  function authorise(address account) external {
    require(msg.sender == owner, "Not owner");
    authorised[account] = true;
  }

  function deauthorise(address account) external {
    require(msg.sender == owner, "Not owner");
    authorised[account] = false;
  }

  // ── Helpers called by Futures / Options contracts ─────────────────────────

  /// @notice Increase `user`'s encrypted balance by `amount`.
  function increaseCollateral(address user, uint64 amount) external onlyAuthorised {
    euint64 enc = FHE.asEuint64(amount);
    if (FHE.isInitialized(_collateral[user])) {
      _collateral[user] = FHE.add(_collateral[user], enc);
    } else {
      _collateral[user] = enc;
    }
    FHE.allowThis(_collateral[user]);
    FHE.allow(_collateral[user], user);
  }

  /// @notice Decrease `user`'s encrypted balance by `amount`.
  ///         Clamped to available balance via FHE.select — never underflows.
  function decreaseCollateral(address user, uint64 amount) external onlyAuthorised {
    euint64 enc = FHE.asEuint64(amount);
    ebool hasEnough = FHE.gte(_collateral[user], enc);
    euint64 actual = FHE.select(hasEnough, enc, _collateral[user]);
    _collateral[user] = FHE.sub(_collateral[user], actual);
    FHE.allowThis(_collateral[user]);
    FHE.allow(_collateral[user], user);
  }

  /// @notice Decrease `user`'s encrypted balance by an already-encrypted `amount`.
  ///         Used by PerpetualFutures when collateral is supplied as encrypted input.
  ///         Clamped to available balance — never underflows.
  function decreaseCollateralEnc(address user, euint64 amount) external onlyAuthorised {
    FHE.allowThis(amount); // ensure this contract can read the handle
    ebool hasEnough = FHE.gte(_collateral[user], amount);
    euint64 actual = FHE.select(hasEnough, amount, _collateral[user]);
    _collateral[user] = FHE.sub(_collateral[user], actual);
    FHE.allowThis(_collateral[user]);
    FHE.allow(_collateral[user], user);
  }

  /// @notice Increase `user`'s encrypted balance by an already-encrypted `amount`.
  ///         Used by LimitOrderBook when a limit order is cancelled.
  function increaseCollateralEnc(address user, euint64 amount) external onlyAuthorised {
    FHE.allowThis(amount);
    if (FHE.isInitialized(_collateral[user])) {
      _collateral[user] = FHE.add(_collateral[user], amount);
    } else {
      _collateral[user] = amount;
    }
    FHE.allowThis(_collateral[user]);
    FHE.allow(_collateral[user], user);
  }

  /// @notice Encrypted transfer between two users. Uses FHE.select so the
  ///         deduction is clamped to balance if insufficient.
  function transferCollateral(address from, address to, uint64 amount) external onlyAuthorised {
    euint64 enc = FHE.asEuint64(amount);
    ebool hasEnough = FHE.gte(_collateral[from], enc);
    euint64 actual = FHE.select(hasEnough, enc, FHE.asEuint64(0));
    _collateral[from] = FHE.sub(_collateral[from], actual);
    
    if (FHE.isInitialized(_collateral[to])) {
      _collateral[to] = FHE.add(_collateral[to], actual);
    } else {
      _collateral[to] = actual;
    }

    FHE.allowThis(_collateral[from]);
    FHE.allow(_collateral[from], from);
    FHE.allowThis(_collateral[to]);
    FHE.allow(_collateral[to], to);
  }
}
