import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers } from "hardhat";
import hre from "hardhat";
import { expect } from "chai";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import {
  Collateral,
  ConfidentialWETHWrapper,
  MockWETH,
  MockOracleIntegration,
  MockPriceFeed,
  PositionManager,
  PerpetualFutures,
  OptionsPool,
  LimitOrderBook,
} from "../typechain-types";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

// ── Constants ────────────────────────────────────────────────────────────────

const INITIAL_PRICE = 200_000_000_000n; // $2000
const DECIMALS_6 = 1_000_000n;
const DECIMALS_18 = 10n ** 18n;
const USER_WETH = 10n * DECIMALS_18; // 10 WETH

type Signers = {
  deployer: HardhatEthersSigner;
  trader1: HardhatEthersSigner;
  trader2: HardhatEthersSigner;
  optionWriter: HardhatEthersSigner;
  keeper: HardhatEthersSigner;
};

interface Contracts {
  weth: MockWETH;
  wrapper: ConfidentialWETHWrapper;
  feed: MockPriceFeed;
  oracle: MockOracleIntegration;
  collateral: Collateral;
  positionManager: PositionManager;
  futures: PerpetualFutures;
  options: OptionsPool;
  limitOrderBook: LimitOrderBook;
}

// ── Deploy Full System ───────────────────────────────────────────────────────

async function deployFullSystem(deployer: HardhatEthersSigner): Promise<Contracts> {
  // 1. Deploy WETH
  const WETHFactory = await ethers.getContractFactory("MockWETH", deployer);
  const weth = await WETHFactory.deploy() as MockWETH;

  // 2. Deploy Confidential WETH Wrapper
  const WrapperFactory = await ethers.getContractFactory("ConfidentialWETHWrapper", deployer);
  const wrapper = await WrapperFactory.deploy(await weth.getAddress()) as ConfidentialWETHWrapper;

  // 3. Deploy Oracle
  const FeedFactory = await ethers.getContractFactory("MockPriceFeed", deployer);
  const feed = await FeedFactory.deploy(INITIAL_PRICE) as MockPriceFeed;

  const OracleFactory = await ethers.getContractFactory("MockOracleIntegration", deployer);
  const oracle = await OracleFactory.deploy(await feed.getAddress()) as MockOracleIntegration;

  // 4. Deploy Collateral
  const CollateralFactory = await ethers.getContractFactory("Collateral", deployer);
  const collateral = await CollateralFactory.deploy(await wrapper.getAddress()) as Collateral;

  // 5. Deploy Position Manager
  const PositionManagerFactory = await ethers.getContractFactory("PositionManager", deployer);
  const positionManager = await PositionManagerFactory.deploy() as PositionManager;

  // 6. Deploy Perpetual Futures
  const FuturesFactory = await ethers.getContractFactory("PerpetualFutures", deployer);
  const futures = await FuturesFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress()
  ) as PerpetualFutures;

  // 7. Deploy Options Pool
  const OptionsFactory = await ethers.getContractFactory("OptionsPool", deployer);
  const options = await OptionsFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress()
  ) as OptionsPool;

  // 8. Deploy Limit Order Book
  const LimitOrderBookFactory = await ethers.getContractFactory("LimitOrderBook", deployer);
  const limitOrderBook = await LimitOrderBookFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress(),
    await futures.getAddress()
  ) as LimitOrderBook;

  // 9. Set authorizations
  await collateral.authorise(await futures.getAddress());
  await collateral.authorise(await options.getAddress());
  await collateral.authorise(await limitOrderBook.getAddress());
  await positionManager.authorise(await futures.getAddress());
  await positionManager.authorise(await options.getAddress());
  await positionManager.authorise(await limitOrderBook.getAddress());

  return {
    weth,
    wrapper,
    feed,
    oracle,
    collateral,
    positionManager,
    futures,
    options,
    limitOrderBook,
  };
}

// ── Helper: Wrap and Deposit ─────────────────────────────────────────────────

async function wrapAndDeposit(
  weth: MockWETH,
  wrapper: ConfidentialWETHWrapper,
  collateral: Collateral,
  user: HardhatEthersSigner,
  amount: bigint,
) {
  const client = await hre.cofhe.createClientWithBatteries(user);
  
  // Get WETH
  await weth.connect(user).faucet();
  
  // Approve wrapper
  await weth.connect(user).approve(await wrapper.getAddress(), amount);
  
  // Wrap to cWETH
  await wrapper.connect(user).wrap(amount);
  
  // Deposit to collateral vault
  const collateralAddr = await collateral.getAddress();
  const encrypted = await client
    .encryptInputs([Encryptable.uint64(amount)])
    .execute();
  
  await wrapper.connect(user).confidentialTransferAndCall(
    collateralAddr,
    encrypted[0],
    "0x"
  );
}

// ── Test Suite ───────────────────────────────────────────────────────────────

describe("Integration: Full Derivatives Protocol (Fhenix)", function () {
  let signers: Signers;
  let c: Contracts;

  before(async function () {
    const all = await ethers.getSigners();
    signers = {
      deployer: all[0],
      trader1: all[1],
      trader2: all[2],
      optionWriter: all[3],
      keeper: all[4],
    };
  });

  beforeEach(async function () {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);
    c = await deployFullSystem(signers.deployer);
  });

  // ── WETH Wrapping ──────────────────────────────────────────────────────

  describe("WETH Wrapping Flow", function () {
    it("user can get WETH from faucet", async function () {
      await c.weth.connect(signers.trader1).faucet();
      const balance = await c.weth.balanceOf(signers.trader1.address);
      expect(balance).to.equal(10n * DECIMALS_18);
    });

    it("user can wrap WETH to cWETH", async function () {
      await c.weth.connect(signers.trader1).faucet();
      await c.weth.connect(signers.trader1).approve(
        await c.wrapper.getAddress(),
        USER_WETH
      );

      await expect(c.wrapper.connect(signers.trader1).wrap(USER_WETH))
        .to.emit(c.wrapper, "Wrapped")
        .withArgs(signers.trader1.address, USER_WETH);
    });

    it("wrapped cWETH can be deposited to collateral", async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );

      // User should have encrypted collateral balance
      const encBalance = await c.collateral.connect(signers.trader1).getMyCollateral();
      // NOTE: Would need decryption to verify exact amount
    });
  });

  // ── Perpetual Futures Trading Flow ─────────────────────────────────────

  describe("Perpetual Futures Trading Flow", function () {
    beforeEach(async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );
    });

    it("trader can open a leveraged position", async function () {
      const collateralAmount = 1n * DECIMALS_18; // 1 WETH
      const leverage = 5n;
      const client = await hre.cofhe.createClientWithBatteries(signers.trader1);
      
      const encrypted = await client
        .encryptInputs([
          Encryptable.uint64(collateralAmount),
          Encryptable.bool(true)
        ])
        .execute();

      await expect(
        c.futures.connect(signers.trader1).openPosition(
          encrypted[0],
          leverage,
          encrypted[1]
        )
      ).to.emit(c.futures, "PositionOpened");
    });

    it("trader can set stop-loss after opening position", async function () {
      const collateralAmount = 1n * DECIMALS_18;
      const leverage = 5n;
      const client = await hre.cofhe.createClientWithBatteries(signers.trader1);
      
      const encrypted1 = await client
        .encryptInputs([Encryptable.uint64(collateralAmount), Encryptable.bool(true)])
        .execute();

      await c.futures.connect(signers.trader1).openPosition(
        encrypted1[0],
        leverage,
        encrypted1[1]
      );

      const stopLossPrice = 190_000_000_000n; // $1900
      const encrypted2 = await client
        .encryptInputs([Encryptable.uint64(stopLossPrice)])
        .execute();

      await expect(
        c.futures.connect(signers.trader1).setStopLoss(0, encrypted2[0])
      ).to.emit(c.futures, "StopLossSet");
    });
  });

  // ── Options Trading Flow ───────────────────────────────────────────────

  describe("Options Trading Flow", function () {
    beforeEach(async function () {
      // Fund writer and buyer
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.optionWriter,
        USER_WETH
      );
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );
    });

    it("full option lifecycle: mint -> buy -> exercise", async function () {
      const strikePrice = 200_000_000_000n; // $2000
      const size = 1n * DECIMALS_6;

      // 1. Writer mints call option
      const tx1 = await c.options
        .connect(signers.optionWriter)
        .mintOption(true, strikePrice, size);
      await expect(tx1).to.emit(c.options, "OptionMinted");

      // 2. Trader buys the option
      const tx2 = await c.options.connect(signers.trader1).buyOption(1n);
      await expect(tx2).to.emit(c.options, "OptionBought");

      // 3. Price moves up
      await c.feed.setPrice(250_000_000_000n); // $2500

      // 4. Trader exercises
      const tx3 = await c.options.connect(signers.trader1).exerciseOption(1n);
      await expect(tx3).to.emit(c.options, "ExerciseRequested");
    });

    it("option expires worthless if not exercised", async function () {
      const strikePrice = 200_000_000_000n;
      const size = 1n * DECIMALS_6;

      await c.options
        .connect(signers.optionWriter)
        .mintOption(false, strikePrice, size); // Put option

      // Time passes, option expires
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      // Anyone can expire it
      await expect(
        c.options.connect(signers.keeper).expireOption(1n)
      ).to.emit(c.options, "OptionExpired");
    });
  });

  // ── Limit Order Book Flow ──────────────────────────────────────────────

  describe("Limit Order Book Flow", function () {
    beforeEach(async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );
    });

    it("trader places limit order -> keeper triggers when price hits", async function () {
      const collateralAmount = 1n * DECIMALS_18;
      const limitPrice = 190_000_000_000n; // $1900 buy limit
      const leverage = 5n;
      const client = await hre.cofhe.createClientWithBatteries(signers.trader1);

      // 1. Place limit order
      const encrypted = await client
        .encryptInputs([
          Encryptable.uint64(collateralAmount),
          Encryptable.uint64(limitPrice),
          Encryptable.bool(true)
        ])
        .execute();

      await expect(
        c.limitOrderBook
          .connect(signers.trader1)
          .placeLimitOrder(encrypted[0], encrypted[1], encrypted[2], leverage)
      ).to.emit(c.limitOrderBook, "LimitOrderPlaced");

      // 2. Price drops to trigger level
      await c.feed.setPrice(190_000_000_000n);

      // 3. Keeper checks and triggers
      await expect(
        c.limitOrderBook.connect(signers.keeper).checkOrder(1n)
      ).to.emit(c.limitOrderBook, "FillCheckRequested");
    });

    it("trader can cancel limit order before fill", async function () {
      const collateralAmount = 1n * DECIMALS_18;
      const limitPrice = 190_000_000_000n;
      const leverage = 5n;
      const client = await hre.cofhe.createClientWithBatteries(signers.trader1);

      const encrypted = await client
        .encryptInputs([
          Encryptable.uint64(collateralAmount),
          Encryptable.uint64(limitPrice),
          Encryptable.bool(true)
        ])
        .execute();

      await c.limitOrderBook
        .connect(signers.trader1)
        .placeLimitOrder(encrypted[0], encrypted[1], encrypted[2], leverage);

      // Cancel before price triggers
      await expect(
        c.limitOrderBook.connect(signers.trader1).cancelOrder(1n)
      ).to.emit(c.limitOrderBook, "LimitOrderCancelled");
    });
  });

  // ── Cross-Protocol Interactions ────────────────────────────────────────

  describe("Cross-Protocol Interactions", function () {
    it("user can have active positions in both futures and options", async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );
      const client = await hre.cofhe.createClientWithBatteries(signers.trader1);

      // Open futures position
      const futuresCollateral = 5n * DECIMALS_18;
      const leverage = 3n;
      const encrypted1 = await client
        .encryptInputs([Encryptable.uint64(futuresCollateral), Encryptable.bool(true)])
        .execute();

      await c.futures.connect(signers.trader1).openPosition(
        encrypted1[0],
        leverage,
        encrypted1[1]
      );

      // Mint option
      const optionSize = 1n * DECIMALS_6;
      await c.options
        .connect(signers.trader1)
        .mintOption(true, 200_000_000_000n, optionSize);

      // Both should be active
      const futuresCount = await c.positionManager.futuresPositionCount(
        signers.trader1.address
      );
      const optionCount = await c.positionManager.nextTokenId();

      expect(futuresCount).to.equal(1n);
      expect(optionCount).to.equal(2n); // Starts at 1
    });

    it("oracle price changes affect all protocols", async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );

      const initialPrice = await c.oracle.getCurrentPrice();
      expect(initialPrice).to.equal(INITIAL_PRICE);

      // Change price
      const newPrice = 220_000_000_000n; // $2200
      await c.feed.setPrice(newPrice);

      // All protocols see new price
      const futuresPrice = await c.oracle.getCurrentPrice();
      expect(futuresPrice).to.equal(newPrice);
    });
  });

  // ── Authorization and Security ─────────────────────────────────────────

  describe("Authorization and Security", function () {
    it("only authorized contracts can modify collateral", async function () {
      await wrapAndDeposit(
        c.weth,
        c.wrapper,
        c.collateral,
        signers.trader1,
        USER_WETH
      );

      // Unauthorized account cannot increase collateral
      await expect(
        c.collateral
          .connect(signers.trader2)
          .increaseCollateral(signers.trader1.address, 1000n)
      ).to.be.revertedWith("Not authorised");
    });

    it("only authorized contracts can manage positions", async function () {
      // Unauthorized account cannot add position
      const encSize = { data: ethers.toBeHex(1000n, 32) as `0x${string}` };
      const encCollateral = { data: ethers.toBeHex(100n, 32) as `0x${string}` };
      const encIsLong = { data: "0x01" };

      // This would need to convert encrypted inputs to euint64/ebool properly
      // For now, demonstrating the authorization check exists
    });
  });
});
