// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IERC7984Receiver.sol";

/**
 * @title FHERC20
 * @notice Basic implementation of ERC-7984 confidential token standard
 * @dev Simplified version focusing on core functionality needed for derivatives
 */
abstract contract FHERC20 {
  // Token metadata
  string public name;
  string public symbol;
  uint8 public decimals;

  // Encrypted balances
  mapping(address => euint64) private _confidentialBalances;

  // Total supply (could be encrypted or public depending on requirements)
  uint256 public totalSupply;

  // Events
  event Transfer(address indexed from, address indexed to, uint256 value);
  event ConfidentialTransfer(
    address indexed from,
    address indexed to,
    bytes32 encryptedAmount
  );

  error InsufficientBalance();
  error InvalidRecipient();

  constructor(string memory _name, string memory _symbol, uint8 _decimals) {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
  }

  /**
   * @notice Get encrypted balance of an account
   */
  function confidentialBalanceOf(
    address account
  ) public view returns (euint64) {
    return _confidentialBalances[account];
  }

  /**
   * @notice Transfer confidential tokens
   * @param to Recipient address
   * @param amount Encrypted amount to transfer
   */
  function confidentialTransfer(
    address to,
    euint64 amount
  ) public returns (euint64) {
    if (to == address(0)) revert InvalidRecipient();

    _transfer(msg.sender, to, amount);

    emit ConfidentialTransfer(msg.sender, to, FHE.unwrap(amount));
    return amount;
  }

  /**
   * @notice Transfer with encrypted input
   */
  function confidentialTransfer(
    address to,
    InEuint64 memory encryptedAmount
  ) public returns (euint64) {
    euint64 amount = FHE.asEuint64(encryptedAmount);
    return confidentialTransfer(to, amount);
  }

  /**
   * @notice Transfer confidential tokens and call receiver
   * @param to Recipient address (must implement IERC7984Receiver)
   * @param encryptedAmount Encrypted amount
   * @param data Additional data
   */
  function confidentialTransferAndCall(
    address to,
    InEuint64 memory encryptedAmount,
    bytes calldata data
  ) external returns (euint64) {
    euint64 amount = FHE.asEuint64(encryptedAmount);

    _transfer(msg.sender, to, amount);

    // Allow receiver contract to operate on the amount handle
    FHE.allow(amount, to);

    // Call receiver hook
    bytes4 response = IERC7984Receiver(to).onConfidentialTransferReceived(
      msg.sender,
      msg.sender,
      FHE.unwrap(amount),
      data
    );

    require(
      response == IERC7984Receiver.onConfidentialTransferReceived.selector,
      "Invalid receiver"
    );

    emit ConfidentialTransfer(msg.sender, to, FHE.unwrap(amount));
    return amount;
  }

  /**
   * @dev Internal transfer function
   */
  function _transfer(address from, address to, euint64 amount) internal {
    euint64 fromBalance = _confidentialBalances[from];

    if (!FHE.isInitialized(fromBalance)) {
      revert InsufficientBalance();
    }

    // Allow this contract to operate on the from balance
    FHE.allowThis(fromBalance);
    FHE.allow(fromBalance, from);

    // Subtract from sender
    euint64 newFromBalance = FHE.sub(fromBalance, amount);
    FHE.allowThis(newFromBalance);
    FHE.allow(newFromBalance, from);
    _confidentialBalances[from] = newFromBalance;

    // Add to recipient
    euint64 toBalance = _confidentialBalances[to];
    euint64 newToBalance;

    if (FHE.isInitialized(toBalance)) {
      newToBalance = FHE.add(toBalance, amount);
    } else {
      newToBalance = amount;
    }

    FHE.allowThis(newToBalance);
    FHE.allow(newToBalance, to);
    _confidentialBalances[to] = newToBalance;
  }

  /**
   * @dev Mint encrypted tokens
   */
  function _mintEncrypted(address to, euint64 amount) internal {
    euint64 toBalance = _confidentialBalances[to];
    euint64 newBalance;

    if (FHE.isInitialized(toBalance)) {
      newBalance = FHE.add(toBalance, amount);
    } else {
      newBalance = amount;
    }

    FHE.allowThis(newBalance);
    FHE.allow(newBalance, to);
    _confidentialBalances[to] = newBalance;

    emit ConfidentialTransfer(address(0), to, FHE.unwrap(amount));
  }

  /**
   * @dev Mint plaintext tokens (encrypted internally)
   */
  function _mint(address to, uint64 amount) internal {
    euint64 encAmount = FHE.asEuint64(amount);
    _mintEncrypted(to, encAmount);
    totalSupply += amount;
  }

  /**
   * @dev Burn tokens
   */
  function _burn(address from, euint64 amount) internal {
    euint64 fromBalance = _confidentialBalances[from];
    require(FHE.isInitialized(fromBalance), "Insufficient balance");

    euint64 newBalance = FHE.sub(fromBalance, amount);
    FHE.allowThis(newBalance);
    FHE.allow(newBalance, from);
    _confidentialBalances[from] = newBalance;

    emit ConfidentialTransfer(from, address(0), FHE.unwrap(amount));
  }
}
