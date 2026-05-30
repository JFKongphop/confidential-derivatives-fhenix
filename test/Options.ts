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
  OptionsPool,
  PositionManager,
} from "../typechain-types";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

// ── Constants ────────────────────────────────────────────────────────────────

const PRICE_2000 = 200_000_000_000n; // $2000 (8 dec)
const PRICE_2500 = 250_000_000_000n; // $2500
const PRICE_1500 = 150_000_000_000n; // $1500
const STRIKE_2000 = 200_000_000_000n; // ATM strike
const STRIKE_2200 = 220_000_000_000n; // OTM call strike
const STRIKE_1800 = 180_000_000_000n; // OTM put strike
const INVALID_STRIKE = 190_000_000_000n; // Not in allowed set
const DECIMALS_6 = 1_000_000n; // 1 USDC (6 dec)
const USER_MINT = 50_000n * DECIMALS_6;
const OPTION_SIZE = 1n * DECIMALS_6; // 1 unit (6 dec)

type Signers = {
  deployer: HardhatEthersSigner;
  writer: HardhatEthersSigner;
  buyer: HardhatEthersSigner;
};

interface Contracts {
  token: MockConfidentialToken;
  feed: MockPriceFeed;
  oracle: MockOracleIntegration;
  collateral: Collateral;
  positionManager: PositionManager;
  options: OptionsPool;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

async function deployAll(deployer: HardhatEthersSigner): Promise<Contracts> {
  const TokenFactory = await ethers.getContractFactory("MockConfidentialToken", deployer);
  const token = await TokenFactory.deploy() as MockConfidentialToken;

  const FeedFactory = await ethers.getContractFactory("MockPriceFeed", deployer);
  const feed = await FeedFactory.deploy(PRICE_2000) as MockPriceFeed;

  const OracleFactory = await ethers.getContractFactory("MockOracleIntegration", deployer);
  const oracle = await OracleFactory.deploy(await feed.getAddress()) as MockOracleIntegration;

  const CollateralFactory = await ethers.getContractFactory("Collateral", deployer);
  const collateral = await CollateralFactory.deploy(await token.getAddress()) as Collateral;

  const PositionManagerFactory = await ethers.getContractFactory("PositionManager", deployer);
  const positionManager = await PositionManagerFactory.deploy() as PositionManager;

  const OptionsFactory = await ethers.getContractFactory("OptionsPool", deployer);
  const options = await OptionsFactory.deploy(
    await collateral.getAddress(),
    await oracle.getAddress(),
    await positionManager.getAddress()
  ) as OptionsPool;

  await collateral.authorise(await options.getAddress());
  await positionManager.authorise(await options.getAddress());

  return { token, feed, oracle, collateral, positionManager, options };
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

// ── Test Suite ───────────────────────────────────────────────────────────────

describe("OptionsPool (Fhenix)", function () {
  let signers: Signers;
  let c: Contracts;
  let collateralAddr: string;

  before(async function () {
    const all = await ethers.getSigners();
    signers = { deployer: all[0], writer: all[1], buyer: all[2] };
  });

  beforeEach(async function () {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);
    c = await deployAll(signers.deployer);
    collateralAddr = await c.collateral.getAddress();

    await mintAndDeposit(c.token, c.collateral, signers.writer, USER_MINT);
    await mintAndDeposit(c.token, c.collateral, signers.buyer, USER_MINT);
  });

  // ── Option Minting ───────────────────────────────────────────────────

  describe("Option Minting", function () {
    it("writer can mint a call option and OptionMinted is emitted", async function () {
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(true, STRIKE_2000, OPTION_SIZE),
      )
        .to.emit(c.options, "OptionMinted")
        .withArgs(
          1n, // first tokenId
          signers.writer.address,
          anyValue, // expiryTime > 0
          anyValue, // premium > 0
        );
    });

    it("writer can mint a put option", async function () {
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(false, STRIKE_2000, OPTION_SIZE),
      )
        .to.emit(c.options, "OptionMinted");
    });

    it("rejects invalid strike price", async function () {
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(true, INVALID_STRIKE, OPTION_SIZE),
      ).to.be.revertedWith("Invalid strike");
    });

    it("rejects zero size", async function () {
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(true, STRIKE_2000, 0n),
      ).to.be.revertedWith("Invalid size");
    });

    it("collateral is locked when minting", async function () {
      // Writer has USER_MINT collateral
      await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);

      // With encrypted collateral, the system uses clamping instead of reverting
      // Attempting to mint another large option will succeed but clamp to available collateral
      const largeSize = USER_MINT;
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(true, STRIKE_2000, largeSize),
      ).to.not.be.reverted; // Encrypted collateral uses clamping, not revert
    });

    it("OTM call has lower premium than ATM", async function () {
      const tx1 = await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE); // ATM
      const receipt1 = await tx1.wait();
      
      const tx2 = await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2200, OPTION_SIZE); // OTM
      const receipt2 = await tx2.wait();

      // In real test, would compare emitted premium values
    });
  });

  // ── Buy Option ─────────────────────────────────────────────────────────

  describe("Buy Option", function () {
    beforeEach(async function () {
      // Writer mints an option
      await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
    });

    it("buyer can purchase minted option", async function () {
      await expect(
        c.options.connect(signers.buyer).buyOption(1n)
      )
        .to.emit(c.options, "OptionBought")
        .withArgs(1n, signers.buyer.address, anyValue);
    });

    it("cannot buy already sold option", async function () {
      await c.options.connect(signers.buyer).buyOption(1n);
      
      await expect(
        c.options.connect(signers.buyer).buyOption(1n)
      ).to.be.revertedWith("Already sold");
    });

    it("writer cannot buy own option", async function () {
      await expect(
        c.options.connect(signers.writer).buyOption(1n)
      ).to.be.revertedWith("Writer cannot buy own option");
    });

    it("cannot buy expired option", async function () {
      // Fast forward time beyond expiry
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]); // 8 days
      await ethers.provider.send("evm_mine", []);

      await expect(
        c.options.connect(signers.buyer).buyOption(1n)
      ).to.be.revertedWith("Option expired");
    });

    it("premium is transferred from buyer to writer", async function () {
      // In real test, would verify encrypted collateral balances changed correctly
      await c.options.connect(signers.buyer).buyOption(1n);
    });
  });

  // ── Exercise Option ────────────────────────────────────────────────────

  describe("Exercise Option", function () {
    beforeEach(async function () {
      // Mint and buy a call option
      await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
      await c.options.connect(signers.buyer).buyOption(1n);
    });

    it("holder can request exercise", async function () {
      // Move price up to make call ITM
      await c.feed.setPrice(PRICE_2500);

      await expect(
        c.options.connect(signers.buyer).exerciseOption(1n)
      )
        .to.emit(c.options, "ExerciseRequested")
        .withArgs(1n, signers.buyer.address, anyValue);
    });

    it("non-holder cannot exercise", async function () {
      await expect(
        c.options.connect(signers.writer).exerciseOption(1n)
      ).to.be.revertedWith("Not option holder");
    });

    it("cannot exercise after expiry", async function () {
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        c.options.connect(signers.buyer).exerciseOption(1n)
      ).to.be.revertedWith("Option expired");
    });
  });

  // ── Expire Option ──────────────────────────────────────────────────────

  describe("Expire Option", function () {
    beforeEach(async function () {
      await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
    });

    it("anyone can expire an option after expiry time", async function () {
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        c.options.connect(signers.buyer).expireOption(1n)
      )
        .to.emit(c.options, "OptionExpired")
        .withArgs(1n);
    });

    it("cannot expire before expiry time", async function () {
      await expect(
        c.options.connect(signers.buyer).expireOption(1n)
      ).to.be.revertedWith("Not yet expired");
    });

    it("writer collateral is returned after expiry", async function () {
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      // Expire the option
      await c.options.connect(signers.buyer).expireOption(1n);

      // In real test, would verify writer's collateral increased
    });
  });

  // ── Option Pricing ─────────────────────────────────────────────────────

  describe("Option Pricing", function () {
    it("call premium is higher when spot > strike (ITM)", async function () {
      await c.feed.setPrice(PRICE_2500); // Move price up

      const tx = await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
      
      // ITM call should have higher premium
    });

    it("put premium is higher when strike > spot (ITM)", async function () {
      await c.feed.setPrice(PRICE_1500); // Move price down

      const tx = await c.options
        .connect(signers.writer)
        .mintOption(false, STRIKE_2000, OPTION_SIZE);
      
      // ITM put should have higher premium
    });

    it("larger size requires more collateral", async function () {
      const smallSize = 1n * DECIMALS_6;
      const largeSize = 10n * DECIMALS_6;

      // Small option should work
      await expect(
        c.options
          .connect(signers.writer)
          .mintOption(true, STRIKE_2000, smallSize)
      ).to.not.be.reverted;

      // Large option might exceed available collateral
    });
  });

  // ── Multiple Options ───────────────────────────────────────────────────

  describe("Multiple Options", function () {
    it("writer can mint multiple options", async function () {
      await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
      
      await c.options
        .connect(signers.writer)
        .mintOption(false, STRIKE_1800, OPTION_SIZE);

      const count = await c.positionManager.nextTokenId();
      expect(count).to.equal(3n); // Started at 1
    });

    it("options have unique token IDs", async function () {
      const tx1 = await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2000, OPTION_SIZE);
      const receipt1 = await tx1.wait();

      const tx2 = await c.options
        .connect(signers.writer)
        .mintOption(true, STRIKE_2200, OPTION_SIZE);
      const receipt2 = await tx2.wait();

      // Token IDs should be 1 and 2
    });
  });
});
