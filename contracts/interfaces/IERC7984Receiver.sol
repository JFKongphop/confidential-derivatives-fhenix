// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IERC7984Receiver
 * @notice Interface for contracts that want to support confidentialTransferAndCall from FHERC20 tokens
 * @dev Implement this interface in contracts that need to receive FHERC20 tokens via confidentialTransferAndCall
 */
interface IERC7984Receiver {
  /**
   * @notice Called by FHERC20 token contract when tokens are transferred via confidentialTransferAndCall
   * @param operator The address which initiated the transfer
   * @param from The address which previously owned the tokens
   * @param encryptedAmount The encrypted amount of tokens transferred
   * @param data Additional data with no specified format
   * @return bytes4 Must return the function selector to confirm the transfer was accepted
   */
  function onConfidentialTransferReceived(
    address operator,
    address from,
    bytes32 encryptedAmount,
    bytes calldata data
  ) external returns (bytes4);
}
