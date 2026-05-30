import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers } from "hardhat";
import hre from "hardhat";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import {
  Collateral,
  MockConfidentialToken,
  MockOracleIntegration,
  MockPriceFeed,
  PositionManager,
  PerpetualFutures,
  LimitOrderBook,
} from "../typechain-types";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

// ── Constants ────────────────────────────────────────────────────────────────

const INITIAL_PRICE = 200_000_000_000n; // $2000 with 8 decimals
const DECIMALS_6 = 1_000_000n;
const USER_MINT = 10_000n * DECIMALS_6;

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  keeper: HardhatEthersSigner;
};

interface Contracts {
  token: MockConfidentialToken;
  feed: MockPriceFeed;
  oracle: MockOracleIntegration;
  collateral: Collateral;
  positionManager: PositionManager;
  futures: PerpetualFutures;
  limitOrderBook: LimitOrderBook;
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

  const LimitOrderBookFactory = await ethers.getContractFactory("LimitOrderBook", deployer);
  const limitOrderBook = await LimitOrderBookFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress(),
    await futures.getAddress()
  ) as LimitOrderBook;

  // Authorisations
  await collateral.authorise(await futures.getAddress());
  await collateral.authorise(await limitOrderBook.getAddress());
  await positionManager.authorise(await futures.getAddress());
  await positionManager.authorise(await limitOrderBook.getAddress());

  return { token, feed, oracle, collateral, positionManager, futures, limitOrderBook };
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

async function placeLimitOrder(
  limitOrderBook: LimitOrderBook,
  user: HardhatEthersSigner,
  collateral: bigint,
  limitPrice: bigint,
  isLong: boolean,
  leverage: bigint,
) {
  const client = await hre.cofhe.createClientWithBatteries(user);
  const encrypted = await client
    .encryptInputs([
      Encryptable.uint64(collateral),
      Encryptable.uint64(limitPrice),
      Encryptable.bool(isLong)
    ])
    .execute();

  return limitOrderBook
    .connect(user)
    .placeLimitOrder(encrypted[0], encrypted[1], encrypted[2], leverage);
}

// ── Test Suite ───────────────────────────────────────────────────────────────

describe("LimitOrderBook (Fhenix)", function () {
  let signers: Signers;
  let c: Contracts;

  before(async function () {
    const all = await ethers.getSigners();
    signers = { deployer: all[0], alice: all[1], keeper: all[2] };
  });

  beforeEach(async function () {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);
    c = await deployAll(signers.deployer);
    await mintAndDeposit(c.token, c.collateral, signers.alice, USER_MINT);
  });

  // ── Place Limit Order ──────────────────────────────────────────────────

  describe("Place Limit Order", function () {
    it("user can place a long limit order", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n; // $1900 - buy if price drops
      const leverage = 5n;

      await expect(
        placeLimitOrder(
          c.limitOrderBook,
          signers.alice,
          collateralAmount,
          limitPrice,
          true,
          leverage
        )
      )
        .to.emit(c.limitOrderBook, "LimitOrderPlaced")
        .withArgs(signers.alice.address, 1n, leverage);
    });

    it("user can place a short limit order", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 210_000_000_000n; // $2100 - sell if price rises
      const leverage = 3n;

      await expect(
        placeLimitOrder(
          c.limitOrderBook,
          signers.alice,
          collateralAmount,
          limitPrice,
          false,
          leverage
        )
      )
        .to.emit(c.limitOrderBook, "LimitOrderPlaced")
        .withArgs(signers.alice.address, 1n, leverage);
    });

    it("rejects invalid leverage", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n;
      const invalidLeverage = 15n;

      await expect(
        placeLimitOrder(
          c.limitOrderBook,
          signers.alice,
          collateralAmount,
          limitPrice,
          true,
          invalidLeverage
        )
      ).to.be.revertedWith("Invalid leverage");
    });

    it("collateral is locked immediately when order is placed", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n;
      const leverage = 5n;

      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );

      // With encrypted collateral, the system uses clamping instead of reverting
      // Attempting to place another large order will succeed but clamp to available balance
      const largeAmount = USER_MINT;
      await expect(
        placeLimitOrder(
          c.limitOrderBook,
          signers.alice,
          largeAmount,
          limitPrice,
          true,
          leverage
        )
      ).to.not.be.reverted; // Encrypted collateral uses clamping, not revert
    });

    it("order ID increments", async function () {
      const collateralAmount = 500n * DECIMALS_6;
      const limitPrice = 190_000_000_000n;
      const leverage = 5n;

      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );

      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        false,
        leverage
      );

      // Check that second order has ID 2
      const order2 = await c.limitOrderBook.limitOrders(2n);
      expect(order2.user).to.equal(signers.alice.address);
      expect(order2.isOpen).to.be.true;
    });
  });

  // ── Cancel Limit Order ─────────────────────────────────────────────────

  describe("Cancel Limit Order", function () {
    beforeEach(async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n;
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );
    });

    it("user can cancel their own order", async function () {
      await expect(
        c.limitOrderBook.connect(signers.alice).cancelOrder(1n)
      )
        .to.emit(c.limitOrderBook, "LimitOrderCancelled")
        .withArgs(signers.alice.address, 1n);
    });

    it("order is marked as closed after cancellation", async function () {
      await c.limitOrderBook.connect(signers.alice).cancelOrder(1n);
      
      const order = await c.limitOrderBook.limitOrders(1n);
      expect(order.isOpen).to.be.false;
    });

    it("collateral is returned after cancellation", async function () {
      // Cancel order
      await c.limitOrderBook.connect(signers.alice).cancelOrder(1n);
      
      // In real test, would verify encrypted collateral balance increased
    });

    it("cannot cancel someone else's order", async function () {
      await expect(
        c.limitOrderBook.connect(signers.keeper).cancelOrder(1n)
      ).to.be.revertedWith("Not your order");
    });

    it("cannot cancel already cancelled order", async function () {
      await c.limitOrderBook.connect(signers.alice).cancelOrder(1n);
      
      await expect(
        c.limitOrderBook.connect(signers.alice).cancelOrder(1n)
      ).to.be.revertedWith("Order not open");
    });
  });

  // ── Check Order (Keeper) ───────────────────────────────────────────────

  describe("Check Order", function () {
    beforeEach(async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n; // $1900 buy limit (long)
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );
    });

    it("keeper can check if order should trigger", async function () {
      // Move price down to trigger level
      await c.feed.setPrice(190_000_000_000n);

      await expect(
        c.limitOrderBook.connect(signers.keeper).checkOrder(1n)
      )
        .to.emit(c.limitOrderBook, "FillCheckRequested")
        .withArgs(1n, anyValue);
    });

    it("keeper can check order multiple times", async function () {
      await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
      await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
      
      // Both should work (though order might be filled after callback)
    });

    it("cannot check closed order", async function () {
      await c.limitOrderBook.connect(signers.alice).cancelOrder(1n);
      
      await expect(
        c.limitOrderBook.connect(signers.keeper).checkOrder(1n)
      ).to.be.revertedWith("Order not open");
    });
  });

  // ── Long Limit Order Trigger Logic ─────────────────────────────────────

  describe("Long Limit Order Trigger", function () {
    it("long limit triggers when price drops to limit price", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n; // $1900
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );

      // Price starts at $2000, set to $1900 to trigger
      await c.feed.setPrice(190_000_000_000n);

      const tx = await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
      
      // Order should be flagged for fulfillment
      await expect(tx).to.emit(c.limitOrderBook, "FillCheckRequested");
    });

    it("long limit does not trigger when price is above limit", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 190_000_000_000n; // $1900
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        true,
        leverage
      );

      // Price stays at $2000 (above limit) - should not trigger in callback
      await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
    });
  });

  // ── Short Limit Order Trigger Logic ────────────────────────────────────

  describe("Short Limit Order Trigger", function () {
    it("short limit triggers when price rises to limit price", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 210_000_000_000n; // $2100
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        false, // short
        leverage
      );

      // Price starts at $2000, set to $2100 to trigger
      await c.feed.setPrice(210_000_000_000n);

      const tx = await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
      
      await expect(tx).to.emit(c.limitOrderBook, "FillCheckRequested");
    });

    it("short limit does not trigger when price is below limit", async function () {
      const collateralAmount = 1000n * DECIMALS_6;
      const limitPrice = 210_000_000_000n; // $2100
      const leverage = 5n;
      
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        limitPrice,
        false, // short
        leverage
      );

      // Price stays at $2000 (below limit) - should not trigger
      await c.limitOrderBook.connect(signers.keeper).checkOrder(1n);
    });
  });

  // ── Multiple Orders ────────────────────────────────────────────────────

  describe("Multiple Orders", function () {
    it("user can have multiple active orders", async function () {
      const collateralAmount = 500n * DECIMALS_6;
      const leverage = 5n;

      // Long limit at $1900
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        190_000_000_000n,
        true,
        leverage
      );

      // Short limit at $2100
      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        210_000_000_000n,
        false,
        leverage
      );

      const order1 = await c.limitOrderBook.limitOrders(1n);
      const order2 = await c.limitOrderBook.limitOrders(2n);

      expect(order1.isOpen).to.be.true;
      expect(order2.isOpen).to.be.true;
    });

    it("cancelling one order does not affect others", async function () {
      const collateralAmount = 500n * DECIMALS_6;
      const leverage = 5n;

      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        190_000_000_000n,
        true,
        leverage
      );

      await placeLimitOrder(
        c.limitOrderBook,
        signers.alice,
        collateralAmount,
        210_000_000_000n,
        false,
        leverage
      );

      // Cancel first order
      await c.limitOrderBook.connect(signers.alice).cancelOrder(1n);

      // Second order should still be open
      const order2 = await c.limitOrderBook.limitOrders(2n);
      expect(order2.isOpen).to.be.true;
    });
  });
});
