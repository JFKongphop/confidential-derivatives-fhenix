// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "./Collateral.sol";
import "./OracleIntegration.sol";
import "./PositionManager.sol";
import "./PricingEngine.sol";

/// @title PerpetualFutures - Core perpetual futures trading protocol
/// @notice Users open long/short positions with 1-10× leverage.
///         Position sizes, collateral, AND direction are stored encrypted,
///         so observers cannot determine if a user is long or short —
///         preventing front-running and MEV on position direction.
///
/// Decimal conventions:
///   • All prices: 8 decimals  (Chainlink)
///   • Collateral / sizes: 6 decimals (USDC)
contract PerpetualFutures {
  using PricingEngine for *;

  // ── Constants ────────────────────────────────────────────────────────────

  uint256 public constant MAINTENANCE_MARGIN_BPS = 500; // 5%
  uint256 public constant LIQUIDATION_BONUS_BPS = 100; // 1%
  uint256 public constant MIN_LEVERAGE = 1;
  uint256 public constant MAX_LEVERAGE = 10;
  uint256 public constant BPS_DENOMINATOR = 10_000;
  uint256 public constant FUNDING_RATE_BPS = 10;   // 0.1% per interval
  uint256 public constant FUNDING_INTERVAL = 8 hours; // charged every 8 hours

  // ── Immutables ───────────────────────────────────────────────────────────

  Collateral public immutable collateral;
  OracleIntegration public immutable oracle;
  PositionManager public immutable positionManager;

  // ── Request counter ────────────────────────────────────────────────────────

  uint256 private _nextRequestId = 1;

  // ── Pending liquidation requests ─────────────────────────────────────────

  struct LiquidationRequest {
    address user;
    uint256 positionId;
    address liquidator;
    bytes32 sizeHandle;
    bytes32 collateralHandle;
    bytes32 isLongHandle;
  }

  mapping(uint256 => LiquidationRequest) public pendingLiquidations;

  // ── Trigger orders (stop-loss / take-profit) ──────────────────────────────

  /// @dev Stores encrypted trigger prices per position.
  ///      Both handles are zero (unwrapped bytes32(0)) when not set.
  struct TriggerOrder {
    euint64 stopLoss;   // Encrypted price; if current price crosses → close (protective)
    euint64 takeProfit; // Encrypted price; if current price crosses → close (profit taking)
    bool hasStopLoss;
    bool hasTakeProfit;
  }

  struct TriggerRequest {
    address user;
    uint256 positionId;
    uint256 currentPrice;
    bytes32 triggeredHandle; // ebool: was the trigger condition met?
    bytes32 sizeHandle;
    bytes32 collateralHandle;
    bytes32 isLongHandle;
  }

  mapping(address => mapping(uint256 => TriggerOrder)) private _triggers;
  mapping(uint256 => TriggerRequest) public pendingTriggers;

  event StopLossSet(address indexed user, uint256 positionId);
  event TakeProfitSet(address indexed user, uint256 positionId);
  event TriggerCheckRequested(
    address indexed user, 
    uint256 positionId, 
    uint256 requestId
  );
  event TriggerExecuted(
    address indexed user, 
    uint256 positionId, 
    uint256 exitPrice
  );

  // ── Encrypted cumulative PnL tracker ──────────────────────────────────────

  /// @dev Running sum of realised P&L (net of losses). Stored encrypted per user.
  mapping(address => euint64) private _realizedPnl;

  event PnLUpdated(address indexed user, bytes32 pnlHandle);

  struct CloseRequest {
    address user;
    uint256 positionId;
    uint256 currentPrice;
    bytes32 sizeHandle;
    bytes32 collateralHandle;
    bytes32 isLongHandle;
  }

  mapping(uint256 => CloseRequest) public pendingCloses;

  // ── Events ───────────────────────────────────────────────────────────────

  event PositionOpened(
    address indexed user, 
    uint256 positionId, 
    uint256 entryPrice,
    bytes32 collateralHandle
  );
  event PositionCloseRequested(
    address indexed user, 
    uint256 positionId, 
    uint256 requestId
  );
  event PositionClosed(
    address indexed user, 
    uint256 positionId, 
    uint256 exitPrice
  );
  event LiquidationRequested(
    address indexed user, 
    uint256 positionId, 
    address liquidator, 
    uint256 requestId
  );
  event Liquidated(
    address indexed user, 
    uint256 positionId, 
    address indexed liquidator, 
    uint256 liquidationPrice
  );

  // ── Constructor ──────────────────────────────────────────────────────────

  constructor(
    address collateralAddr, 
    address oracleAddr, 
    address positionManagerAddr
  ) {
    collateral = Collateral(collateralAddr);
    oracle = OracleIntegration(oracleAddr);
    positionManager = PositionManager(positionManagerAddr);
  }

  // ── Open position ────────────────────────────────────────────────────────

  /// @notice Open a leveraged long or short position.
  /// @param  encAmount   Off-chain encrypted collateral (InEuint64)
  /// @param  leverage    Leverage multiplier (1–10) — plaintext for on-chain bounds check
  /// @param  encIsLong   Off-chain encrypted direction: true=long, false=short
  /// @return positionId  The new position identifier
  function openPosition(
    InEuint64 memory encAmount,
    uint64 leverage,
    InEbool memory encIsLong
  ) external returns (uint256 positionId) {
    require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "Invalid leverage");

    uint256 currentPrice = oracle.getCurrentPrice();

    // Verify and decrypt the encrypted inputs
    euint64 encCollateral = FHE.asEuint64(encAmount);
    ebool encDirection  = FHE.asEbool(encIsLong);
    euint64 encLeverage   = FHE.asEuint64(leverage);
    euint64 encSize       = FHE.mul(encCollateral, encLeverage);

    // Grant ACL permissions
    FHE.allowThis(encSize);
    FHE.allow(encSize, address(positionManager));
    FHE.allow(encSize, msg.sender);
    FHE.allowThis(encCollateral);
    FHE.allow(encCollateral, address(positionManager));
    FHE.allow(encCollateral, address(collateral));
    FHE.allow(encCollateral, msg.sender);
    FHE.allowThis(encDirection);
    FHE.allow(encDirection, address(positionManager));
    FHE.allow(encDirection, msg.sender);

    // Deduct collateral from vault using encrypted amount — no plaintext leak
    collateral.decreaseCollateralEnc(msg.sender, encCollateral);

    positionId = positionManager.addFuturesPosition(
      msg.sender,
      encSize,
      encCollateral,
      encDirection,
      currentPrice
    );

    emit PositionOpened(msg.sender, positionId, currentPrice, FHE.unwrap(encCollateral));
  }

  // ── Close position (async) ────────────────────────────────────────────────

  /// @notice Initiate position close. Triggers async decryption of size & collateral
  ///         so P&L can be settled in the callback.
  ///         NOTE: In Fhenix, decryption is handled differently. This pattern may need
  ///         adjustment based on Fhenix's async decryption API.
  /// @return requestId The decryption request identifier
  function closePosition(uint256 positionId) external returns (uint256 requestId) {
    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(
      msg.sender, 
      positionId
    );

    uint256 currentPrice = oracle.getCurrentPrice();

    bytes32 sizeHandle = FHE.unwrap(pos.size);
    bytes32 collateralHandle = FHE.unwrap(pos.collateralUsed);
    bytes32 isLongHandle = FHE.unwrap(pos.isLong);

    // NOTE: Fhenix async decryption may use different API
    // This is a placeholder for the async decryption pattern
    requestId = _nextRequestId++;
    pendingCloses[requestId] = CloseRequest({
      user: msg.sender,
      positionId: positionId,
      currentPrice: currentPrice,
      sizeHandle: sizeHandle,
      collateralHandle: collateralHandle,
      isLongHandle: isLongHandle
    });

    emit PositionCloseRequested(msg.sender, positionId, requestId);
  }

  /// @notice Callback: settles P&L and returns collateral ± P&L to user.
  ///         NOTE: This callback pattern is Zama-specific. Fhenix may require
  ///         different approach for async decryption.
  function fulfillClose(
    uint256 requestId, 
    uint64 decryptedSize,
    uint64 decryptedCollateral,
    bool decryptedIsLong
  ) external {
    CloseRequest memory req = pendingCloses[requestId];
    require(req.user != address(0), "Unknown request");

    delete pendingCloses[requestId];

    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(
      req.user, 
      req.positionId
    );

    // Calculate P&L using public prices and decrypted size
    uint256 delta = req.currentPrice > pos.entryPrice
      ? req.currentPrice - pos.entryPrice
      : pos.entryPrice - req.currentPrice;

    // pnlAmount in USDC (6 dec): size × delta / entryPrice
    uint64 pnlAmount = uint64((uint256(decryptedSize) * delta) / pos.entryPrice);

    // Funding cost: 0.1% per 8h interval held
    uint256 intervals = (block.timestamp - pos.openedAt) / FUNDING_INTERVAL;
    uint64 fundingCost = uint64((uint256(decryptedCollateral) * FUNDING_RATE_BPS * intervals) / BPS_DENOMINATOR);

    bool profitable = (req.currentPrice > pos.entryPrice) == decryptedIsLong;

    if (profitable) {
      uint64 gains = pnlAmount > fundingCost ? pnlAmount - fundingCost : 0;
      collateral.increaseCollateral(req.user, decryptedCollateral + gains);
      _accumulatePnl(req.user, gains, true);
    } else {
      uint64 totalDeduction = pnlAmount + fundingCost;
      uint64 returnAmt = totalDeduction < decryptedCollateral ? decryptedCollateral - totalDeduction : 0;
      if (returnAmt > 0) {
        collateral.increaseCollateral(req.user, returnAmt);
      }
      _accumulatePnl(req.user, totalDeduction < decryptedCollateral ? 0 : totalDeduction - decryptedCollateral, false);
    }

    positionManager.removeFuturesPosition(req.user, req.positionId);

    emit PositionClosed(req.user, req.positionId, req.currentPrice);
  }

  // ── Liquidation ───────────────────────────────────────────────────────────

  /// @notice Trigger a decryption-based liquidation check.
  function liquidatePosition(
    address user, 
    uint256 positionId
  ) external returns (uint256 requestId) {
    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(
      user, 
      positionId
    );

    bytes32 sizeHandle = FHE.unwrap(pos.size);
    bytes32 collateralHandle = FHE.unwrap(pos.collateralUsed);
    bytes32 isLongHandle = FHE.unwrap(pos.isLong);

    requestId = _nextRequestId++;
    pendingLiquidations[requestId] = LiquidationRequest({
      user: user,
      positionId: positionId,
      liquidator: msg.sender,
      sizeHandle: sizeHandle,
      collateralHandle: collateralHandle,
      isLongHandle: isLongHandle
    });

    emit LiquidationRequested(user, positionId, msg.sender, requestId);
  }

  /// @notice Callback: verifies the position is underwater and executes liquidation.
  function fulfillLiquidation(
    uint256 requestId, 
    uint64 decryptedSize,
    uint64 decryptedCollateral,
    bool decryptedIsLong
  ) external {
    LiquidationRequest memory req = pendingLiquidations[requestId];
    require(req.user != address(0), "Unknown request");

    delete pendingLiquidations[requestId];

    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(
      req.user, 
      req.positionId
    );
    
    uint256 currentPrice = oracle.getCurrentPrice();
    uint256 delta = currentPrice > pos.entryPrice ? currentPrice - pos.entryPrice : pos.entryPrice - currentPrice;
    uint64 mtmLoss = decryptedIsLong && currentPrice < pos.entryPrice
    ? uint64((uint256(decryptedSize) * delta) / pos.entryPrice)
    : (!decryptedIsLong && currentPrice > pos.entryPrice ? uint64((uint256(decryptedSize) * delta) / pos.entryPrice) : 0);
    
    uint64 maintenanceRequired = uint64(
      (uint256(decryptedCollateral) * MAINTENANCE_MARGIN_BPS) 
      / BPS_DENOMINATOR
    );
    uint64 remainingCollateral = mtmLoss < decryptedCollateral ? decryptedCollateral - mtmLoss : 0;
    require(remainingCollateral < maintenanceRequired, "Not liquidatable");

    uint256 intervals = (block.timestamp - pos.openedAt) / FUNDING_INTERVAL;
    uint64 fundingCost = uint64(
      (uint256(decryptedCollateral) * FUNDING_RATE_BPS * intervals) 
      / BPS_DENOMINATOR
    );

    uint64 bonus = uint64(
      (uint256(decryptedCollateral) * LIQUIDATION_BONUS_BPS) 
      / BPS_DENOMINATOR
    );
    if (bonus > 0) {
      collateral.increaseCollateral(req.liquidator, bonus);
    }
    
    uint64 afterBonus = remainingCollateral > bonus ? remainingCollateral - bonus : 0;
    uint64 userReturn = fundingCost < afterBonus ? afterBonus - fundingCost : 0;
    if (userReturn > 0) {
      collateral.increaseCollateral(req.user, userReturn);
    }

    positionManager.removeFuturesPosition(req.user, req.positionId);

    emit Liquidated(req.user, req.positionId, req.liquidator, currentPrice);
  }

  // ── View ─────────────────────────────────────────────────────────────────

  function getPositionSize(uint256 positionId) external view returns (euint64) {
    return positionManager.getFuturesPosition(msg.sender, positionId).size;
  }

  function getPositionCollateral(uint256 positionId) external view returns (euint64) {
    return positionManager.getFuturesPosition(msg.sender, positionId).collateralUsed;
  }

  // ── Stop-Loss / Take-Profit ───────────────────────────────────────────────

  function setStopLoss(
    uint256 positionId,
    InEuint64 memory encPrice
  ) external {
    positionManager.getFuturesPosition(msg.sender, positionId);

    euint64 encSL = FHE.asEuint64(encPrice);
    FHE.allowThis(encSL);
    FHE.allow(encSL, msg.sender);

    _triggers[msg.sender][positionId].stopLoss = encSL;
    _triggers[msg.sender][positionId].hasStopLoss = true;

    emit StopLossSet(msg.sender, positionId);
  }

  function setTakeProfit(
    uint256 positionId,
    InEuint64 memory encPrice
  ) external {
    positionManager.getFuturesPosition(msg.sender, positionId);

    euint64 encTP = FHE.asEuint64(encPrice);
    FHE.allowThis(encTP);
    FHE.allow(encTP, msg.sender);

    _triggers[msg.sender][positionId].takeProfit = encTP;
    _triggers[msg.sender][positionId].hasTakeProfit = true;

    emit TakeProfitSet(msg.sender, positionId);
  }

  function checkTrigger(
    address user,
    uint256 positionId
  ) external returns (uint256 requestId) {
    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(user, positionId);
    TriggerOrder storage trig = _triggers[user][positionId];
    require(trig.hasStopLoss || trig.hasTakeProfit, "No trigger set");

    uint256 currentPrice = oracle.getCurrentPrice();
    euint64 encCurrentPrice = FHE.asEuint64(uint64(currentPrice));

    ebool triggered = FHE.asEbool(false);

    if (trig.hasStopLoss) {
      ebool slLong  = FHE.lt(encCurrentPrice, trig.stopLoss);
      ebool slShort = FHE.gt(encCurrentPrice, trig.stopLoss);
      ebool slFired = FHE.select(pos.isLong, slLong, slShort);
      triggered = FHE.or(triggered, slFired);
    }

    if (trig.hasTakeProfit) {
      ebool tpLong  = FHE.gt(encCurrentPrice, trig.takeProfit);
      ebool tpShort = FHE.lt(encCurrentPrice, trig.takeProfit);
      ebool tpFired = FHE.select(pos.isLong, tpLong, tpShort);
      triggered = FHE.or(triggered, tpFired);
    }

    requestId = _nextRequestId++;
    pendingTriggers[requestId] = TriggerRequest({
      user: user,
      positionId: positionId,
      currentPrice: currentPrice,
      triggeredHandle: FHE.unwrap(triggered),
      sizeHandle: FHE.unwrap(pos.size),
      collateralHandle: FHE.unwrap(pos.collateralUsed),
      isLongHandle: FHE.unwrap(pos.isLong)
    });

    emit TriggerCheckRequested(user, positionId, requestId);
  }

  function fulfillTrigger(
    uint256 requestId,
    bool triggered,
    uint64 decryptedSize,
    uint64 decryptedCollateral,
    bool decryptedIsLong
  ) external {
    TriggerRequest memory req = pendingTriggers[requestId];
    require(req.user != address(0), "Unknown request");

    delete pendingTriggers[requestId];

    if (!triggered) return;

    delete _triggers[req.user][req.positionId];

    PositionManager.FuturesPosition memory pos = positionManager.getFuturesPosition(
      req.user,
      req.positionId
    );

    uint256 delta = req.currentPrice > pos.entryPrice
      ? req.currentPrice - pos.entryPrice
      : pos.entryPrice - req.currentPrice;

    uint64 pnlAmount  = uint64((uint256(decryptedSize) * delta) / pos.entryPrice);
    uint256 intervals = (block.timestamp - pos.openedAt) / FUNDING_INTERVAL;
    uint64 fundingCost = uint64((uint256(decryptedCollateral) * FUNDING_RATE_BPS * intervals) / BPS_DENOMINATOR);
    bool profitable   = (req.currentPrice > pos.entryPrice) == decryptedIsLong;

    if (profitable) {
      uint64 gains = pnlAmount > fundingCost ? pnlAmount - fundingCost : 0;
      collateral.increaseCollateral(req.user, decryptedCollateral + gains);
      _accumulatePnl(req.user, gains, true);
    } else {
      uint64 totalDeduction = pnlAmount + fundingCost;
      uint64 returnAmt = totalDeduction < decryptedCollateral ? decryptedCollateral - totalDeduction : 0;
      if (returnAmt > 0) collateral.increaseCollateral(req.user, returnAmt);
      _accumulatePnl(req.user, totalDeduction < decryptedCollateral ? 0 : totalDeduction - decryptedCollateral, false);
    }

    positionManager.removeFuturesPosition(req.user, req.positionId);
    emit TriggerExecuted(req.user, req.positionId, req.currentPrice);
  }

  // ── Encrypted PnL History ─────────────────────────────────────────────────

  function getMyRealizedPnL() external view returns (euint64) {
    return _realizedPnl[msg.sender];
  }

  function _accumulatePnl(address user, uint64 amount, bool isGain) internal {
    if (amount == 0) return;
    euint64 current = _realizedPnl[user];
    euint64 delta   = FHE.asEuint64(amount);
    euint64 updated;
    if (!FHE.isInitialized(current)) {
      updated = isGain ? delta : FHE.asEuint64(0);
    } else {
      updated = isGain ? FHE.add(current, delta) : current;
    }
    FHE.allowThis(updated);
    FHE.allow(updated, user);
    _realizedPnl[user] = updated;
    emit PnLUpdated(user, FHE.unwrap(updated));
  }
}
