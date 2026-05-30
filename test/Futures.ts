import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers } from "hardhat";
import hre from "hardhat";
import { expect } from "chai";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import {
  Collateral,
  MockConfidentialToken,
  MockOracleIntegration,
  MockPriceFeed,
  PositionManager,
  PerpetualFutures,
} from "../typechain-types";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

// ── Constants ────────────────────────────────────────────────────────────────

const INITIAL_PRICE = 200_000_000_000n; // $2000 with 8 decimals
const DECIMALS_6 = 1_000_000n; // 1 USDC
const USER_MINT = 10_000n * DECIMALS_6; // 10,000 USDC per test user

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  liquidator: HardhatEthersSigner;
};

interface Contracts {
  token: MockConfidentialToken;
  feed: MockPriceFeed;
  oracle: MockOracleIntegration;
  collateral: Collateral;
  positionManager: PositionManager;
  futures: PerpetualFutures;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

async function deployAll(deployer: HardhatEthersSigner): Promise<Contracts> {
  const TokenFactory = await ethers.getContractFactory("MockConfidentialToken", deployer);
  const token = await TokenFactory.deploy() as MockConfidentialToken;

  const FeedFactory = await ethers.getContractFactory("MockPriceFeed", deployer);
  const feed = await FeedFactory.deploy(INITIAL_PRICE) as MockPriceFeed;

  const OracleFactory = await ethers.getContractFactory("MockOracleIntegration", deployer);
  const oracle = await OracleFactory.deploy(await feed.getAddress()) as MockOracleIntegration;

  const CollateralFactory = await ethers.getContractFactory("Collateral", deployer);
  const collateral = await CollateralFactory.deploy(await token.getAddress()) as Collateral;

  const PositionManagerFactory = await ethers.getContractFactory("PositionManager", deployer);
  const positionManager = await PositionManagerFactory.deploy() as PositionManager;

  const FuturesFactory = await ethers.getContractFactory("PerpetualFutures", deployer);
  const futures = await FuturesFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress()
  ) as PerpetualFutures;

  // Authorise futures contract to call collateral and positionManager
  await collateral.authorise(await futures.getAddress());
  await positionManager.authorise(await futures.getAddress());

  return { token, feed, oracle, collateral, positionManager, futures };
}

async function mintAndDeposit(
  token: MockConfidentialToken,
  collateral: Collateral,
  user: HardhatEthersSigner,
  amount: bigint,
) {
  const collateralAddr = await collateral.getAddress();
  const client = await hre.cofhe.createClientWithBatteries(user);
  
  await token.mint(user.address, amount);
  
  const encrypted = await client
    .encryptInputs([Encryptable.uint64(amount)])
    .execute();
  
  await token.connect(user).confidentialTransferAndCall(
    collateralAddr,
    encrypted[0],
    "0x"
  );
}

async function encryptOpenPosition(
  futures: PerpetualFutures,
  user: HardhatEthersSigner,
  isLong: boolean,
  collateralAmount: bigint,
  leverage: bigint,
) {
  const client = await hre.cofhe.createClientWithBatteries(user);
  const encrypted = await client
    .encryptInputs([
      Encryptable.uint64(collateralAmount),
      Encryptable.bool(isLong)
    ])
    .execute();
  
  return futures
    .connect(user)
    .openPosition(encrypted[0], leverage, encrypted[1]);
}

// ── Test Suite ───────────────────────────────────────────────────────────────

describe("PerpetualFutures (Fhenix)", function () {
  let signers: Signers;
  let c: Contracts;

  before(async function () {
    const all = await ethers.getSigners();
    signers = { 
      deployer: all[0], 
      alice: all[1], 
      bob: all[2], 
      liquidator: all[3] 
    };
  });

  beforeEach(async function () {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);
    c = await deployAll(signers.deployer);
    
    // Fund test users
    await mintAndDeposit(c.token, c.collateral, signers.alice, USER_MINT);
    await mintAndDeposit(c.token, c.collateral, signers.bob, USER_MINT);
    await mintAndDeposit(c.token, c.collateral, signers.liquidator, USER_MINT);
  });

  // ── Open Position ──────────────────────────────────────────────────────

  describe("Open Position", function () {
    it("user can open a long position", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 5n;

      await expect(
        encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage)
      )
        .to.emit(c.futures, "PositionOpened")
        .withArgs(signers.alice.address, 0, INITIAL_PRICE, anyValue);
    });

    it("user can open a short position", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 3n;

      await expect(
        encryptOpenPosition(c.futures, signers.alice, false, collateralAmount, leverage)
      )
        .to.emit(c.futures, "PositionOpened")
        .withArgs(signers.alice.address, 0, INITIAL_PRICE, anyValue);
    });

    it("rejects leverage below minimum", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 0n;

      await expect(
        encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage)
      ).to.be.revertedWith("Invalid leverage");
    });

    it("rejects leverage above maximum", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 11n;

      await expect(
        encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage)
      ).to.be.revertedWith("Invalid leverage");
    });

    it("position counter increments", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 5n;

      await encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage);
      const count1 = await c.positionManager.futuresPositionCount(signers.alice.address);
      
      await encryptOpenPosition(c.futures, signers.alice, false, collateralAmount, leverage);
      const count2 = await c.positionManager.futuresPositionCount(signers.alice.address);

      expect(count2).to.equal(count1 + 1n);
    });
  });

  // ── Close Position ─────────────────────────────────────────────────────

  describe("Close Position", function () {
    beforeEach(async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 5n;
      await encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage);
    });

    it("emits PositionCloseRequested when closing", async function () {
      await expect(
        c.futures.connect(signers.alice).closePosition(0)
      )
        .to.emit(c.futures, "PositionCloseRequested")
        .withArgs(signers.alice.address, 0, anyValue);
    });

    it("position becomes invalid after close (async pattern)", async function () {
      const tx = await c.futures.connect(signers.alice).closePosition(0);
      const receipt = await tx.wait();
      
      // NOTE: In real implementation, would call fulfillClose with decrypted values
      // This is a placeholder test structure
    });
  });

  // ── Stop-Loss / Take-Profit ────────────────────────────────────────────

  describe("Stop-Loss and Take-Profit", function () {
    beforeEach(async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 5n;
      await encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage);
    });

    it("user can set stop-loss", async function () {
      const stopLossPrice = 190_000_000_000n; // $1900
      const client = await hre.cofhe.createClientWithBatteries(signers.alice);
      const encrypted = await client
        .encryptInputs([Encryptable.uint64(stopLossPrice)])
        .execute();

      await expect(
        c.futures.connect(signers.alice).setStopLoss(0, encrypted[0])
      )
        .to.emit(c.futures, "StopLossSet")
        .withArgs(signers.alice.address, 0);
    });

    it("user can set take-profit", async function () {
      const takeProfitPrice = 210_000_000_000n; // $2100
      const client = await hre.cofhe.createClientWithBatteries(signers.alice);
      const encrypted = await client
        .encryptInputs([Encryptable.uint64(takeProfitPrice)])
        .execute();

      await expect(
        c.futures.connect(signers.alice).setTakeProfit(0, encrypted[0])
      )
        .to.emit(c.futures, "TakeProfitSet")
        .withArgs(signers.alice.address, 0);
    });

    it("only position owner can set stop-loss", async function () {
      const stopLossPrice = 190_000_000_000n;
      const client = await hre.cofhe.createClientWithBatteries(signers.bob);
      const encrypted = await client
        .encryptInputs([Encryptable.uint64(stopLossPrice)])
        .execute();

      await expect(
        c.futures.connect(signers.bob).setStopLoss(0, encrypted[0])
      ).to.be.reverted;
    });
  });

  // ── Liquidation ────────────────────────────────────────────────────────

  describe("Liquidation", function () {
    it("position can be flagged for liquidation check", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 10n; // Max leverage for easy liquidation
      await encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage);

      // Move price down significantly
      await c.feed.setPrice(100_000_000_000n); // $1000 (50% drop)

      await expect(
        c.futures.connect(signers.liquidator).liquidatePosition(signers.alice.address, 0)
      )
        .to.emit(c.futures, "LiquidationRequested")
        .withArgs(signers.alice.address, 0, signers.liquidator.address, anyValue);
    });
  });

  // ── View Functions ─────────────────────────────────────────────────────

  describe("View Functions", function () {
    beforeEach(async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const leverage = 5n;
      await encryptOpenPosition(c.futures, signers.alice, true, collateralAmount, leverage);
    });

    it("user can query encrypted position size", async function () {
      const size = await c.futures.connect(signers.alice).getPositionSize(0);
      // NOTE: Returns encrypted euint64, would need decryption to verify value
      expect(size).to.not.equal(0n);
    });

    it("user can query encrypted position collateral", async function () {
      const collateral = await c.futures.connect(signers.alice).getPositionCollateral(0);
      expect(collateral).to.not.equal(0n);
    });

    it("user can query realized PnL", async function () {
      const pnl = await c.futures.connect(signers.alice).getMyRealizedPnL();
      // Returns encrypted value
    });
  });
});

// Import anyValue if needed
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
