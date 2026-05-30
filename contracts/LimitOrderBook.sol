// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "./Collateral.sol";
import "./OracleIntegration.sol";
import "./PositionManager.sol";
import "./PerpetualFutures.sol";

/// @title LimitOrderBook — Private encrypted limit orders for perpetual futures
///
/// @notice Users submit limit orders where BOTH the collateral amount AND the
///         trigger price are encrypted. Nobody — not even a keeper — knows at
///         what price you want to enter, or how much you want to trade.
///
///         Flow:
///           1. User calls `placeLimitOrder(encCollateral, encLimitPrice, encIsLong, leverage)`
///              • Collateral is locked in the vault immediately (decreaseCollateralEnc)
///              • Encrypted handles are stored on-chain
///           2. Any keeper calls `checkOrder(orderId)` at any time
///              • FHE comparison: for a long, `currentPrice <= limitPrice` → triggered
///              • For a short, `currentPrice >= limitPrice` → triggered
///              • Result (`ebool`) is requested for public decryption
///           3. `fulfillOrder(requestId, ...)` callback
///              • If triggered: open the position via PositionManager directly
///              • If not triggered: do nothing (keeper wasted gas, not user's problem)
///           4. User can `cancelOrder(orderId)` any time before fill to recover collateral
///
/// Decimal conventions (same as PerpetualFutures):
///   • Prices: 8 decimals (Chainlink)
///   • Collateral / sizes: 6 decimals (USDC)
contract LimitOrderBook {

  // ── Constants ─────────────────────────────────────────────────────────────

  uint256 public constant MIN_LEVERAGE = 1;
  uint256 public constant MAX_LEVERAGE = 10;

  // ── Immutables ────────────────────────────────────────────────────────────

  Collateral       public immutable collateral;
  OracleIntegration public immutable oracle;
  PositionManager  public immutable positionManager;
  PerpetualFutures public immutable futures;

  // ── State ─────────────────────────────────────────────────────────────────

  uint256 private _nextOrderId   = 1;
  uint256 private _nextRequestId = 1;

  struct LimitOrder {
    address user;
    uint64  leverage;
    euint64 collateral;   // Encrypted collateral locked for this order
    euint64 limitPrice;   // Encrypted target entry price
    ebool   isLong;       // Encrypted direction
    bool    isOpen;
  }

  struct FillRequest {
    uint256 orderId;
    uint256 currentPrice;
    bytes32 triggeredHandle; // ebool — was the limit condition met?
    bytes32 collateralHandle;
    bytes32 limitPriceHandle;
    bytes32 isLongHandle;
  }

  mapping(uint256 => LimitOrder)  public limitOrders;
  mapping(uint256 => FillRequest) public pendingFills;

  // ── Events ────────────────────────────────────────────────────────────────

  event LimitOrderPlaced(address indexed user, uint256 orderId, uint64 leverage);
  event LimitOrderCancelled(address indexed user, uint256 orderId);
  event FillCheckRequested(uint256 indexed orderId, uint256 requestId);
  event LimitOrderFilled(address indexed user, uint256 orderId, uint256 fillPrice, uint256 positionId);
  event LimitOrderExpired(uint256 indexed orderId); // triggered = false

  // ── Constructor ───────────────────────────────────────────────────────────

  constructor(
    address collateralAddr,
    address oracleAddr,
    address positionManagerAddr,
    address futuresAddr
  ) {
    collateral    = Collateral(collateralAddr);
    oracle        = OracleIntegration(oracleAddr);
    positionManager = PositionManager(positionManagerAddr);
    futures       = PerpetualFutures(futuresAddr);
  }

  // ── Place order ───────────────────────────────────────────────────────────

  /// @notice Place a limit order with fully encrypted collateral, price, and direction.
  /// @param  encCollateral  Encrypted USDC collateral to lock for this order
  /// @param  encLimitPrice  Encrypted target entry price (8 decimals)
  /// @param  encIsLong      Encrypted direction: true = long, false = short
  /// @param  leverage       Plaintext leverage (1–10); bounds checked on-chain
  /// @return orderId        The new order identifier
  function placeLimitOrder(
    InEuint64 memory encCollateral,
    InEuint64 memory encLimitPrice,
    InEbool memory encIsLong,
    uint64 leverage
  ) external returns (uint256 orderId) {
    require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "Invalid leverage");

    euint64 encColl  = FHE.asEuint64(encCollateral);
    euint64 encPrice = FHE.asEuint64(encLimitPrice);
    ebool   encDir   = FHE.asEbool(encIsLong);

    // Grant ACL to this contract so it can use handles in checkOrder/fulfillOrder
    FHE.allowThis(encColl);
    FHE.allow(encColl, msg.sender);
    FHE.allow(encColl, address(collateral));
    FHE.allowThis(encPrice);
    FHE.allow(encPrice, msg.sender);
    FHE.allowThis(encDir);
    FHE.allow(encDir, msg.sender);
    FHE.allow(encColl, address(positionManager));
    FHE.allow(encDir,  address(positionManager));

    // Lock collateral immediately
    collateral.decreaseCollateralEnc(msg.sender, encColl);

    orderId = _nextOrderId++;
    limitOrders[orderId] = LimitOrder({
      user:       msg.sender,
      leverage:   leverage,
      collateral: encColl,
      limitPrice: encPrice,
      isLong:     encDir,
      isOpen:     true
    });

    emit LimitOrderPlaced(msg.sender, orderId, leverage);
  }

  /// @notice Cancel an open limit order and return locked collateral to vault.
  function cancelOrder(uint256 orderId) external {
    LimitOrder storage order = limitOrders[orderId];
    require(order.isOpen, "Order not open");
    require(order.user == msg.sender, "Not your order");

    order.isOpen = false;

    collateral.increaseCollateralEnc(msg.sender, order.collateral);

    emit LimitOrderCancelled(msg.sender, orderId);
  }

  // ── Check / Fill ──────────────────────────────────────────────────────────

  /// @notice Keeper calls this to check whether the limit condition is met.
  ///         The FHE comparison is:
  ///           Long:  currentPrice <= limitPrice  (buy limit)
  ///           Short: currentPrice >= limitPrice  (sell limit)
  ///         Direction is encrypted — the comparison is done entirely in FHE.
  ///         NOTE: Fhenix's async decryption may differ from this pattern.
  /// @return requestId  Async decryption request ID
  function checkOrder(uint256 orderId) external returns (uint256 requestId) {
    LimitOrder storage order = limitOrders[orderId];
    require(order.isOpen, "Order not open");

    uint256 currentPrice    = oracle.getCurrentPrice();
    euint64 encCurrentPrice = FHE.asEuint64(uint64(currentPrice));

    // Long limit: fill when price ≤ limitPrice
    // Short limit: fill when price ≥ limitPrice
    ebool longCondition  = FHE.lte(encCurrentPrice, order.limitPrice);
    ebool shortCondition = FHE.gte(encCurrentPrice, order.limitPrice);
    ebool triggered      = FHE.select(order.isLong, longCondition, shortCondition);

    requestId = _nextRequestId++;
    pendingFills[requestId] = FillRequest({
      orderId:          orderId,
      currentPrice:     currentPrice,
      triggeredHandle:  FHE.unwrap(triggered),
      collateralHandle: FHE.unwrap(order.collateral),
      limitPriceHandle: FHE.unwrap(order.limitPrice),
      isLongHandle:     FHE.unwrap(order.isLong)
    });

    emit FillCheckRequested(orderId, requestId);
  }

  /// @notice Callback: if triggered, open the futures position for the user.
  ///         NOTE: This callback pattern is adapted from Zama.
  function fulfillOrder(
    uint256 requestId,
    bool triggered,
    uint64 decryptedCollateral
  ) external {
    FillRequest memory req = pendingFills[requestId];
    require(req.orderId != 0, "Unknown request");

    delete pendingFills[requestId];

    LimitOrder storage order = limitOrders[req.orderId];
    if (!order.isOpen) return; // Already cancelled

    if (!triggered) {
      emit LimitOrderExpired(req.orderId);
      return;
    }

    order.isOpen = false;

    // Open the position using decrypted collateral and encrypted handles
    euint64 encLeverage = FHE.asEuint64(order.leverage);
    euint64 encSize     = FHE.mul(FHE.asEuint64(decryptedCollateral), encLeverage);

    FHE.allowThis(encSize);
    FHE.allow(encSize, address(positionManager));
    FHE.allow(encSize, order.user);
    FHE.allow(order.collateral, address(positionManager));

    uint256 positionId = positionManager.addFuturesPosition(
      order.user,
      encSize,
      order.collateral,
      order.isLong,
      req.currentPrice
    );

    emit LimitOrderFilled(order.user, req.orderId, req.currentPrice, positionId);
  }
}
