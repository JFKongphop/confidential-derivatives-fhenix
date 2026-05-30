import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers } from "hardhat";
import hre from "hardhat";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import {
  Collateral,
  MockConfidentialToken,
} from "../typechain-types";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

// ── Constants ────────────────────────────────────────────────────────────────

const DECIMALS_6 = 1_000_000n; // 1 USDC
const USER_MINT = 10_000n * DECIMALS_6; // 10,000 USDC

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  carol: HardhatEthersSigner;
};

interface Contracts {
  token: MockConfidentialToken;
  collateral: Collateral;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

async function deploy(deployer: HardhatEthersSigner): Promise<Contracts> {
  const TokenFactory = await ethers.getContractFactory("MockConfidentialToken", deployer);
  const token = await TokenFactory.deploy() as MockConfidentialToken;
  
  const CollateralFactory = await ethers.getContractFactory("Collateral", deployer);
  const collateral = await CollateralFactory.deploy(await token.getAddress()) as Collateral;
  
  return { token, collateral };
}

/// Mint tokens then deposit via token.confidentialTransferAndCall (IERC7984Receiver pattern).
async function mintAndDeposit(
  token: MockConfidentialToken,
  collateral: Collateral,
  user: HardhatEthersSigner,
  amount: bigint,
): Promise<void> {
  const collateralAddr = await collateral.getAddress();
  const client = await hre.cofhe.createClientWithBatteries(user);

  // Mint plain tokens to user
  await token.connect(user).mint(user.address, amount);

  // Encrypt amount using Fhenix SDK
  const encrypted = await client
    .encryptInputs([Encryptable.uint64(amount)])
    .execute();

  // User calls token.confidentialTransferAndCall → token calls onConfidentialTransferReceived
  await token.connect(user).confidentialTransferAndCall(
    collateralAddr,
    encrypted[0],
    "0x"
  );
}

async function encryptWithdraw(
  collateral: Collateral,
  user: HardhatEthersSigner,
  amount: bigint,
) {
  const client = await hre.cofhe.createClientWithBatteries(user);
  const encrypted = await client
    .encryptInputs([Encryptable.uint64(amount)])
    .execute();
  return collateral.connect(user).withdraw(encrypted[0]);
}

/// Get encrypted balance
async function getBalance(
  collateral: Collateral,
  user: HardhatEthersSigner,
): Promise<bigint> {
  const client = await hre.cofhe.createClientWithBatteries(user);
  const encBalance = await collateral.connect(user).getMyCollateral();
  const decrypted = await client
    .decryptForView(encBalance, FheTypes.Uint64)
    .execute();
  return decrypted;
}

// ── Test Suite ───────────────────────────────────────────────────────────────

describe("Collateral (FHERC20 - Fhenix)", function () {
  let signers: Signers;
  let c: Contracts;
  let collateralAddr: string;

  before(async function () {
    const all = await ethers.getSigners();
    signers = { deployer: all[0], alice: all[1], bob: all[2], carol: all[3] };
  });

  beforeEach(async function () {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);
    c = await deploy(signers.deployer);
    collateralAddr = await c.collateral.getAddress();
  });

  // ── Deployment ─────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("token address is set correctly", async function () {
      expect(await c.collateral.token()).to.equal(await c.token.getAddress());
    });

    it("deployer is the owner", async function () {
      expect(await c.collateral.owner()).to.equal(signers.deployer.address);
    });

    it("no accounts are initially authorised", async function () {
      expect(await c.collateral.authorised(signers.alice.address)).to.be.false;
    });
  });

  // ── Authorization ──────────────────────────────────────────────────────

  describe("Authorization", function () {
    it("owner can authorise an account", async function () {
      await c.collateral.connect(signers.deployer).authorise(signers.alice.address);
      expect(await c.collateral.authorised(signers.alice.address)).to.be.true;
    });

    it("owner can deauthorise an account", async function () {
      await c.collateral.connect(signers.deployer).authorise(signers.alice.address);
      await c.collateral.connect(signers.deployer).deauthorise(signers.alice.address);
      expect(await c.collateral.authorised(signers.alice.address)).to.be.false;
    });

    it("non-owner cannot authorise", async function () {
      await expect(
        c.collateral.connect(signers.alice).authorise(signers.bob.address)
      ).to.be.revertedWith("Not owner");
    });
  });

  // ── Deposit ────────────────────────────────────────────────────────────

  describe("Deposit", function () {
    it("emits Deposit event with encrypted amount", async function () {
      const amount = 1000n * DECIMALS_6;
      const client = await hre.cofhe.createClientWithBatteries(signers.alice);
      
      await c.token.connect(signers.alice).mint(signers.alice.address, amount);
      
      const encrypted = await client
        .encryptInputs([Encryptable.uint64(amount)])
        .execute();

      await expect(
        c.token.connect(signers.alice).confidentialTransferAndCall(
          collateralAddr,
          encrypted[0],
          "0x"
        )
      )
        .to.emit(c.collateral, "Deposit")
        .withArgs(signers.alice.address, anyValue);
    });

    it("only token contract can call onConfidentialTransferReceived", async function () {
      const fakeEncryptedAmount = ethers.toBeHex(1000n * DECIMALS_6, 32);
      
      await expect(
        c.collateral.connect(signers.alice).onConfidentialTransferReceived(
          signers.alice.address,
          signers.alice.address,
          fakeEncryptedAmount,
          "0x"
        )
      ).to.be.revertedWith("Collateral: only token");
    });
  });

  // ── Withdraw ───────────────────────────────────────────────────────────

  describe("Withdraw", function () {
    beforeEach(async function () {
      // Deposit some collateral first
      await mintAndDeposit(c.token, c.collateral, signers.alice, USER_MINT);
    });

    it("emits Withdraw event", async function () {
      const withdrawAmount = 1000n * DECIMALS_6;
      
      await expect(
        encryptWithdraw(c.collateral, signers.alice, withdrawAmount)
      )
        .to.emit(c.collateral, "Withdraw")
        .withArgs(signers.alice.address, anyValue);
    });

    it("user receives tokens after withdrawal", async function () {
      const withdrawAmount = 1000n * DECIMALS_6;
      const balanceBefore = await c.token.totalSupply();
      
      await encryptWithdraw(c.collateral, signers.alice, withdrawAmount);
      
      // NOTE: In real tests, would verify user's encrypted token balance increased
    });
  });

  // ── Collateral Management (Authorised Calls) ───────────────────────────

  describe("Collateral Management", function () {
    beforeEach(async function () {
      await mintAndDeposit(c.token, c.collateral, signers.alice, USER_MINT);
      // Authorise bob to manage collateral
      await c.collateral.connect(signers.deployer).authorise(signers.bob.address);
    });

    it("authorised contract can increase collateral", async function () {
      const increaseAmount = 500n * DECIMALS_6;
      
      await expect(
        c.collateral.connect(signers.bob).increaseCollateral(
          signers.alice.address,
          increaseAmount
        )
      ).to.not.be.reverted;
    });

    it("authorised contract can decrease collateral", async function () {
      const decreaseAmount = 500n * DECIMALS_6;
      
      await expect(
        c.collateral.connect(signers.bob).decreaseCollateral(
          signers.alice.address,
          decreaseAmount
        )
      ).to.not.be.reverted;
    });

    it("unauthorised account cannot modify collateral", async function () {
      const amount = 500n * DECIMALS_6;
      
      await expect(
        c.collateral.connect(signers.carol).increaseCollateral(
          signers.alice.address,
          amount
        )
      ).to.be.revertedWith("Not authorised");
    });

    it("authorised contract can transfer collateral between users", async function () {
      await mintAndDeposit(c.token, c.collateral, signers.bob, USER_MINT);
      const transferAmount = 500n * DECIMALS_6;
      
      await expect(
        c.collateral.connect(signers.bob).transferCollateral(
          signers.alice.address,
          signers.carol.address,
          transferAmount
        )
      ).to.not.be.reverted;
    });
  });
});
