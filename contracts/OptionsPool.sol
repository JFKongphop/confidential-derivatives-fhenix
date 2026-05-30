// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import "./Collateral.sol";
import "./OracleIntegration.sol";
import "./PositionManager.sol";
import "./PricingEngine.sol";

/// @title OptionsPool - European call/put options on ETH/USD
/// @notice Writers deposit collateral and mint options.
///         Buyers pay a premium (Black-Scholes approximation).
///         Options are European — exercisable only before expiry.
///
/// Allowed strikes (8 decimals, Chainlink format):
///   1800e8, 2000e8, 2200e8, 2400e8
///
/// Decimal conventions match PerpetualFutures:
///   • Prices   : 8 dec  (Chainlink)
///   • Premiums : 8 dec  (same as price domain)
///   • Sizes    : 6 dec  (USDC)
contract OptionsPool {
  using PricingEngine for *;

  // ── Constants ─────────────────────────────────────────────────────────────

  uint256 public constant TIME_TO_EXPIRY = 7 days;
  uint256 public constant BPS_DENOMINATOR = 10_000;
  uint256 public constant COLLATERAL_RATIO = 20; // 1/20 = 5% of size as extra collateral

  /// @dev Allowed strike prices (8 decimals)
  uint256[4] public STRIKES = [uint256(1800e8), 2000e8, 2200e8, 2400e8];

  // ── Immutables ────────────────────────────────────────────────────────────

  Collateral public immutable collateral;
  OracleIntegration public immutable oracle;
  PositionManager public immutable positionManager;

  // ── Request counter ──────────────────────────────────────────────────────

  uint256 private _nextRequestId = 1;

  /// @dev Caches the plaintext premium at mint time for use in buyOption.
  mapping(uint256 => uint64) private _premiumCache;

  /// @dev Tracks collateral locked by each writer per option token (encrypted).
  ///      Used to return the writer's margin when an option expires worthless.
  mapping(uint256 => euint64) private _writerLockedCollateral;

  // ── Pending exercise requests ──────────────────────────────────────────────

  struct ExerciseRequest {
    address buyer;
    uint256 tokenId;
    uint256 currentPrice;
    bytes32 itmHandle;
    bytes32 sizeHandle;
    bytes32 strikeHandle;
    bytes32 isCallHandle;
  }

  mapping(uint256 => ExerciseRequest) public pendingExercises;

  // ── Events ────────────────────────────────────────────────────────────────

  event OptionMinted(
    uint256 indexed tokenId,
    address indexed writer,
    uint256 expiryTime,
    uint256 premiumPerContract
  );
  event OptionBought(
    uint256 indexed tokenId, 
    address indexed buyer, 
    uint256 premium
  );
  event ExerciseRequested(
    uint256 indexed tokenId, 
    address indexed buyer, 
    uint256 requestId
  );
  event OptionExercised(
    uint256 indexed tokenId, 
    address indexed buyer, 
    uint256 settlementAmount
  );
  event OptionExpired(uint256 indexed tokenId);

  // ── Constructor ───────────────────────────────────────────────────────────

  constructor(
    address collateralAddr, 
    address oracleAddr, 
    address positionManagerAddr
  ) {
    collateral = Collateral(collateralAddr);
    oracle = OracleIntegration(oracleAddr);
    positionManager = PositionManager(positionManagerAddr);
  }

  // ── Write option ──────────────────────────────────────────────────────────

  /// @notice Writer mints a new option, locking collateral proportional to risk.
  /// @param  isCall      true = call, false = put
  /// @param  strikePrice Strike price (8 decimals); must be in STRIKES array
  /// @param  size        USDC notional (6 decimals)
  /// @return tokenId     Newly minted option identifier
  function mintOption(
    bool isCall, 
    uint256 strikePrice, 
    uint64 size
  ) external returns (uint256 tokenId) {
    require(size > 0, "Invalid size");
    require(_isValidStrike(strikePrice), "Invalid strike");

    uint256 spotPrice = oracle.getCurrentPrice();

    // Compute premium using simplified Black-Scholes
    uint256 call = PricingEngine.blackScholesCall(spotPrice, strikePrice);
    uint256 put = PricingEngine.blackScholesPut(spotPrice, strikePrice);
    uint256 premiumPerContract = isCall ? call : put;

    // Required collateral = premium × size / spotPrice + size / 20
    uint64 requiredCollateral =
      uint64(
        (premiumPerContract * uint256(size)) 
        / spotPrice + uint256(size) 
        / COLLATERAL_RATIO
      );

    // Lock collateral from writer
    collateral.decreaseCollateral(msg.sender, requiredCollateral);

    euint64 encSize    = FHE.asEuint64(size);
    euint64 encPremium = FHE.asEuint64(uint64(premiumPerContract));
    euint64 encStrike  = FHE.asEuint64(uint64(strikePrice));
    ebool encIsCall  = FHE.asEbool(isCall);

    // Grant ACL permissions before passing handles to PositionManager
    FHE.allowThis(encSize);
    FHE.allow(encSize, address(positionManager));
    FHE.allow(encSize, msg.sender);
    FHE.allowThis(encPremium);
    FHE.allow(encPremium, address(positionManager));
    FHE.allow(encPremium, msg.sender);
    FHE.allowThis(encStrike);
    FHE.allow(encStrike, address(positionManager));
    FHE.allow(encStrike, msg.sender);
    FHE.allowThis(encIsCall);
    FHE.allow(encIsCall, address(positionManager));
    FHE.allow(encIsCall, msg.sender);

    tokenId = positionManager.addOptionPosition(
      msg.sender,
      encSize,
      encPremium,
      encStrike,
      encIsCall,
      block.timestamp + TIME_TO_EXPIRY
    );

    _premiumCache[tokenId] = uint64(premiumPerContract);

    euint64 encCollateral = FHE.asEuint64(requiredCollateral);
    FHE.allowThis(encCollateral);
    _writerLockedCollateral[tokenId] = encCollateral;

    FHE.allowThis(encSize);
    FHE.allowThis(encPremium);

    emit OptionMinted(
      tokenId,
      msg.sender,
      block.timestamp + TIME_TO_EXPIRY,
      premiumPerContract
    );
  }

  // ── Buy option ────────────────────────────────────────────────────────────

  /// @notice Buyer purchases an existing option, paying the stored premium.
  ///         Premium is in 8-decimal price units, so we convert to 6-dec USDC.
  /// @param  tokenId The option to purchase
  function buyOption(uint256 tokenId) external {
    PositionManager.OptionPosition memory opt = positionManager.getOptionPosition(tokenId);

    require(block.timestamp < opt.expiryTime, "Option expired");
    require(opt.holder == address(0), "Already sold");
    require(opt.writer != msg.sender, "Writer cannot buy own option");

    // Use premium cached at mint time
    uint64 totalPremium = _premiumCache[tokenId];
    require(totalPremium > 0, "Premium not set");

    // Deduct premium from buyer and credit writer
    collateral.transferCollateral(msg.sender, opt.writer, totalPremium);

    // Grant buyer ACL access to all encrypted fields
    FHE.allow(opt.size, msg.sender);
    FHE.allow(opt.premium, msg.sender);
    FHE.allow(opt.strikePrice, msg.sender);
    FHE.allow(opt.isCall, msg.sender);

    // Register buyer as holder
    positionManager.setOptionHolder(tokenId, msg.sender);

    emit OptionBought(tokenId, msg.sender, totalPremium);
  }

  // ── Exercise option ────────────────────────────────────────────────────────

  /// @notice Holder exercises the option, triggering async decryption of size
  ///         to compute the settlement amount.
  ///         NOTE: Fhenix's async decryption API may differ from this pattern.
  /// @param  tokenId The option token to exercise
  /// @return requestId The decryption request identifier
  function exerciseOption(uint256 tokenId) external returns (uint256) {
    PositionManager.OptionPosition memory opt = positionManager.getOptionPosition(tokenId);

    require(opt.holder == msg.sender, "Not option holder");
    require(block.timestamp < opt.expiryTime, "Option expired");

    uint256 currentPrice = oracle.getCurrentPrice();

    // FHE ITM proof: prove option is in-the-money without revealing strike on-chain
    euint64 encCurrent = FHE.asEuint64(uint64(currentPrice));
    ebool callITM = FHE.gt(encCurrent, opt.strikePrice);
    ebool putITM  = FHE.lt(encCurrent, opt.strikePrice);
    ebool encITM  = FHE.select(opt.isCall, callITM, putITM);

    FHE.allowThis(encITM);

    uint256 requestId = _nextRequestId++;
    pendingExercises[requestId] = ExerciseRequest({
      buyer: msg.sender,
      tokenId: tokenId,
      currentPrice: currentPrice,
      itmHandle: FHE.unwrap(encITM),
      sizeHandle: FHE.unwrap(opt.size),
      strikeHandle: FHE.unwrap(opt.strikePrice),
      isCallHandle: FHE.unwrap(opt.isCall)
    });

    emit ExerciseRequested(tokenId, msg.sender, requestId);
    return requestId;
  }

  /// @notice Callback: computes settlement and pays buyer.
  ///         NOTE: This callback pattern is adapted from Zama.
  function fulfillExercise(
    uint256 requestId, 
    bool itm,
    uint64 decryptedSize,
    uint64 decryptedStrike,
    bool decryptedIsCall
  ) external {
    ExerciseRequest memory req = pendingExercises[requestId];
    require(req.buyer != address(0), "Unknown request");

    delete pendingExercises[requestId];

    require(itm, "Option out of the money");

    PositionManager.OptionPosition memory opt = positionManager.getOptionPosition(req.tokenId);

    // Settlement in USDC (6 dec): (priceDelta / currentPrice) × size
    uint256 priceDelta = PricingEngine.getOptionValue(
      req.currentPrice, 
      uint256(decryptedStrike), 
      decryptedIsCall
    );
    uint64 settlement = uint64((priceDelta * uint256(decryptedSize)) / req.currentPrice);

    if (settlement > 0) {
      collateral.transferCollateral(opt.writer, req.buyer, settlement);
    }

    positionManager.removeOptionPosition(req.tokenId);

    emit OptionExercised(req.tokenId, req.buyer, settlement);
  }

  /// @notice Expire an OTM / unexercised option, releasing writer collateral.
  function expireOption(uint256 tokenId) external {
    PositionManager.OptionPosition memory opt = positionManager.getOptionPosition(tokenId);
    require(block.timestamp >= opt.expiryTime, "Not yet expired");
    
    // Return the writer's locked collateral now that the option has expired worthless.
    euint64 locked = _writerLockedCollateral[tokenId];
    FHE.allow(locked, address(collateral));
    collateral.increaseCollateralEnc(opt.writer, locked);
    positionManager.removeOptionPosition(tokenId);
    
    emit OptionExpired(tokenId);
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  function _isValidStrike(uint256 strike) internal view returns (bool) {
    for (uint256 i = 0; i < STRIKES.length; i++) {
      if (STRIKES[i] == strike) return true;
    }
    return false;
  }
}
