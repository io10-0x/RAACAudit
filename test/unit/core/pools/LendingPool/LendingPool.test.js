import { assert, expect } from "chai";
import hre from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const { ethers } = hre;

const WAD = ethers.parseEther("1");
const RAY = ethers.parseUnits("1", 27);

const WadRayMath = {
  wadToRay: (wad) => (BigInt(wad) * BigInt(RAY)) / BigInt(WAD),
  rayToWad: (ray) => {
    ray = BigInt(ray);
    return (ray * BigInt(WAD)) / BigInt(RAY);
  },
};

function getReserveDataStructure(reserveData) {
  return {
    totalLiquidity: reserveData.totalLiquidity,
    totalScaledUsage: reserveData.totalScaledUsage,
    liquidityIndex: reserveData.liquidityIndex,
    usageIndex: reserveData.usageIndex,
    lastUpdateTimestamp: reserveData.lastUpdateTimestamp,
  };
}

async function getCurrentLiquidityRatePercentage(lendingPool) {
  const rateData = await lendingPool.rateData();
  const currentLiquidityRate = rateData.currentLiquidityRate;
  const percentage = Number(currentLiquidityRate) / 1e25;
  return percentage;
}

async function getCurrentBorrowRatePercentage(lendingPool) {
  const rateData = await lendingPool.rateData();
  const currentUsageRate = rateData.currentUsageRate;
  const percentage = Number(currentUsageRate) / 1e25;
  return percentage;
}

async function getCurrentUtilizationRatePercentage(lendingPool) {
  const reserve = await lendingPool.reserve();
  const totalLiquidity = reserve.totalLiquidity;
  const totalUsage = reserve.totalUsage;

  const utilizationRate =
    Number(totalUsage) / (Number(totalLiquidity) + Number(totalUsage));

  const usageIndex = reserve.usageIndex;
  const usage = totalUsage * (usageIndex / RAY);

  if (totalLiquidity == 0n) {
    return 0;
  }

  // const utilizationRate = (Number(usage) / Number(totalLiquidity)) * 100;
  return utilizationRate * 100;
}

describe("LendingPool", function () {
  let owner, user1, user2, user3;
  let crvusd,
    reserveLibrary,
    raacNFT,
    raacHousePrices,
    stabilityPool,
    raacFCL,
    raacVault;
  let lendingPool,
    attacker,
    ERC777Token,
    rToken,
    mockcrvvault,
    rejectERC721,
    debtToken;
  let deployer;
  let token;

  beforeEach(async function () {
    [owner, user1, user2, user3] = await ethers.getSigners();

    const CrvUSDToken = await ethers.getContractFactory("crvUSDToken");
    crvusd = await CrvUSDToken.deploy(owner.address);

    await crvusd.setMinter(owner.address);

    token = crvusd;

    const RAACHousePrices = await ethers.getContractFactory("RAACHousePrices");
    raacHousePrices = await RAACHousePrices.deploy(owner.address);

    const RAACNFT = await ethers.getContractFactory("RAACNFT");
    raacNFT = await RAACNFT.deploy(
      crvusd.target,
      raacHousePrices.target,
      owner.address
    );

    stabilityPool = { target: owner.address };

    const RToken = await ethers.getContractFactory("RToken");
    rToken = await RToken.deploy(
      "RToken",
      "RToken",
      owner.address,
      crvusd.target
    );

    const erc777Token = await ethers.getContractFactory("ERC777Token");
    ERC777Token = await erc777Token.deploy(owner.address);

    const Attacker = await ethers.getContractFactory("Attacker");
    attacker = await Attacker.deploy(rToken.target, ERC777Token.target);

    const DebtToken = await ethers.getContractFactory("DebtToken");
    debtToken = await DebtToken.deploy("DebtToken", "DT", owner.address);

    const MockCrvVault = await ethers.getContractFactory("MockCrvVault");
    mockcrvvault = await MockCrvVault.deploy(crvusd.target);

    const RejectERC721 = await ethers.getContractFactory("RejectERC721");
    rejectERC721 = await RejectERC721.deploy(raacNFT.target, token.target);

    const initialPrimeRate = ethers.parseUnits("0.1", 27);

    const LendingPool = await ethers.getContractFactory("LendingPool");
    lendingPool = await LendingPool.deploy(
      crvusd.target,
      rToken.target,
      debtToken.target,
      raacNFT.target,
      raacHousePrices.target,
      initialPrimeRate
    );

    const reservelibrary = await ethers.getContractFactory(
      "ReserveLibraryMock"
    );
    reserveLibrary = await reservelibrary.deploy();

    await rToken.setReservePool(lendingPool.target);
    await debtToken.setReservePool(lendingPool.target);

    await rToken.transferOwnership(lendingPool.target);
    await debtToken.transferOwnership(lendingPool.target);

    const mintAmount = ethers.parseEther("1000");
    await crvusd.mint(user1.address, mintAmount);
    await crvusd.mint(user3.address, mintAmount);

    const mintAmount2 = ethers.parseEther("10000000000000000000000");
    await crvusd.mint(user2.address, mintAmount2);

    await crvusd.connect(user1).approve(lendingPool.target, mintAmount);
    await crvusd.connect(user2).approve(lendingPool.target, mintAmount);
    await crvusd.connect(user3).approve(lendingPool.target, mintAmount);

    await raacHousePrices.setOracle(owner.address);
    // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
    await raacHousePrices.setHousePrice(1, ethers.parseEther("100"));

    await ethers.provider.send("evm_mine", []);

    const housePrice = await raacHousePrices.tokenToHousePrice(1);

    const raacHpAddress = await raacNFT.raac_hp();

    const priceFromNFT = await raacNFT.getHousePrice(1);

    const tokenId = 1;
    const amountToPay = ethers.parseEther("100");

    await token.mint(user1.address, amountToPay);

    await token.connect(user1).approve(raacNFT.target, amountToPay);

    await raacNFT.connect(user1).mint(tokenId, amountToPay);

    const depositAmount = ethers.parseEther("1000");
    await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
    await lendingPool.connect(user2).deposit(depositAmount);

    await ethers.provider.send("evm_mine", []);

    expect(await crvusd.balanceOf(rToken.target)).to.equal(
      ethers.parseEther("1000")
    );
  });

  describe("Access Control and Security", function () {
    it("should prevent non-owner from setting prime rate", async function () {
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await expect(
        lendingPool.connect(user1).setPrimeRate(ethers.parseEther("0.05"))
      ).to.be.revertedWithCustomError(lendingPool, "Unauthorized");
    });

    it("should prevent reentrancy attacks on deposit", async function () {
      const depositAmount = ethers.parseEther("1");
      await expect(lendingPool.connect(user1).deposit(depositAmount)).to.not.be
        .reverted;
    });
  });

  describe("Deposit and Withdraw", function () {
    it("should allow user to deposit crvUSD and receive rToken", async function () {
      await lendingPool.connect(user1).deposit(depositAmount);

      await ethers.provider.send("evm_mine", []);

      const rTokenBalance = await rToken.balanceOf(user1.address);
      expect(rTokenBalance).to.equal(depositAmount);

      const crvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(crvUSDBalance).to.equal(ethers.parseEther("900"));

      const debtBalance = await debtToken.balanceOf(user1.address);
      expect(debtBalance).to.equal(0);

      const reserveBalance = await crvusd.balanceOf(rToken.target);
      expect(reserveBalance).to.equal(ethers.parseEther("1100"));
    });

    it("should allow user to withdraw crvUSD by burning rToken", async function () {
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1000")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(0);
      expect(await debtToken.balanceOf(user1.address)).to.equal(0);
      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("1000")
      );
      const depositAmount = ethers.parseEther("100");
      await lendingPool.connect(user1).deposit(depositAmount);
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1100")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(depositAmount);
      expect(await debtToken.balanceOf(user1.address)).to.equal(0);
      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("900")
      );
      await rToken.connect(user1).approve(lendingPool.target, depositAmount);

      const withdrawAmount = ethers.parseEther("10");
      await lendingPool.connect(user1).withdraw(withdrawAmount);
      expect(await debtToken.balanceOf(user1.address)).to.equal(
        ethers.parseEther("0")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(
        ethers.parseEther("90")
      );
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1090")
      );
      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("910")
      );

      await lendingPool.connect(user1).withdraw(depositAmount - withdrawAmount);

      const rTokenBalance = await rToken.balanceOf(user1.address);
      expect(rTokenBalance).to.equal(0);

      const crvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(crvUSDBalance).to.equal(ethers.parseEther("1000"));

      const debtBalance = await debtToken.balanceOf(user1.address);

      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1000")
      );
      expect(debtBalance).to.equal(0);
    });

    it("should prevent withdrawing more than balance", async function () {
      const depositAmount = ethers.parseEther("100");
      const withdrawAmount = ethers.parseEther("200");

      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("1000")
      );
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1000")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(0);
      expect(await debtToken.balanceOf(user1.address)).to.equal(0);

      await lendingPool.connect(user1).deposit(depositAmount);
      await rToken.connect(user1).approve(lendingPool.target, withdrawAmount);

      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("900")
      );
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1100")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(depositAmount);
      expect(await debtToken.balanceOf(user1.address)).to.equal(0);

      await lendingPool.connect(user1).withdraw(withdrawAmount);
      expect(await crvusd.balanceOf(rToken.target)).to.equal(
        ethers.parseEther("1000")
      );

      expect(await crvusd.balanceOf(user1.address)).to.equal(
        ethers.parseEther("1000")
      );
      expect(await rToken.balanceOf(user1.address)).to.equal(0);
      expect(await debtToken.balanceOf(user1.address)).to.equal(0);
    });
  });

  describe("Borrow and Repay", function () {
    beforeEach(async function () {
      const depositAmount = ethers.parseEther("1000");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user2).deposit(depositAmount);

      const tokenId = 1;
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);
    });

    it("should allow user to borrow crvUSD using NFT collateral", async function () {
      const borrowAmount = ethers.parseEther("50");

      await lendingPool.connect(user1).borrow(borrowAmount);

      const crvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(crvUSDBalance).to.equal(ethers.parseEther("1050"));

      const debtBalance = await debtToken.balanceOf(user1.address);

      expect(debtBalance).to.gte(borrowAmount);
    });

    it("should prevent user from borrowing more than allowed", async function () {
      const borrowAmount = ethers.parseEther("900");

      await expect(
        lendingPool.connect(user1).borrow(borrowAmount)
      ).to.be.revertedWithCustomError(
        lendingPool,
        "NotEnoughCollateralToBorrow"
      );
    });

    it("should allow user to repay borrowed crvUSD", async function () {
      const borrowAmount = ethers.parseEther("50");
      await lendingPool.connect(user1).borrow(borrowAmount);

      const debtAmount = await debtToken.balanceOf(user1.address);
      await crvusd
        .connect(user1)
        .approve(rToken.target, debtAmount + ethers.parseEther("0.000001"));
      await lendingPool
        .connect(user1)
        .repay(debtAmount + ethers.parseEther("0.000001"));

      const debtBalance = await debtToken.balanceOf(user1.address);
      expect(debtBalance).to.equal(0);

      const crvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(crvUSDBalance).to.lte(ethers.parseEther("1000"));
      expect(crvUSDBalance).to.gte(ethers.parseEther("999.9999990"));
    });

    it("should only allow user to repay up to the owed amount", async function () {
      const borrowAmount = ethers.parseEther("50");

      await lendingPool.connect(user1).borrow(borrowAmount);

      const debtAmount = await debtToken.balanceOf(user1.address);
      const repayAmount = debtAmount + ethers.parseEther("1");

      await crvusd.connect(user1).approve(rToken.target, repayAmount);

      const initialBalance = await crvusd.balanceOf(user1.address);

      // Let the interest accrue accross 2 blocks
      await ethers.provider.send("evm_mine", []);
      await ethers.provider.send("evm_mine", []);
      await lendingPool.connect(user1).updateState();

      await lendingPool.connect(user1).repay(repayAmount);

      const finalDebt = await debtToken.balanceOf(user1.address);
      const finalBalance = await crvusd.balanceOf(user1.address);

      expect(finalDebt).to.equal(0);
      const balanceDifference = initialBalance - finalBalance;
      const tolerance = ethers.parseEther("0.000001");
      expect(balanceDifference).to.be.closeTo(debtAmount, tolerance);
      expect(balanceDifference).to.be.closeTo(borrowAmount, tolerance);
      expect(balanceDifference).to.be.gt(borrowAmount - tolerance);
    });
    it("should allow user1 to deposit, borrow 10 crvUSD, repay, and verify depositor interest", async function () {
      let expectedBalances = {
        user1: {
          crvUSD: ethers.parseEther("1000"),
          rToken: ethers.parseEther("0"),
          debt: ethers.parseEther("0"),
        },
        user2: {
          crvUSD: ethers.parseEther("8000"),
          rToken: ethers.parseEther("2000"),
          debt: ethers.parseEther("0"),
        },
        rToken: {
          crvUSD: ethers.parseEther("2000"),
        },
      };

      const user2InitialBalance = await crvusd.balanceOf(user2.address);
      expect(user2InitialBalance).to.equal(expectedBalances.user2.crvUSD);

      const depositedAmount = await rToken.balanceOf(user2.address);

      expect(depositedAmount).to.equal(expectedBalances.rToken.crvUSD);

      const initialBalanceOfRToken = await crvusd.balanceOf(rToken.target);
      expect(initialBalanceOfRToken).to.equal(expectedBalances.rToken.crvUSD);

      const borrowAmount = ethers.parseEther("10");
      expect(await crvusd.balanceOf(user1.address)).to.equal(
        expectedBalances.user1.crvUSD
      );
      await lendingPool.connect(user1).borrow(borrowAmount);
      await lendingPool.connect(user1).updateState();

      expectedBalances.user1.crvUSD =
        expectedBalances.user1.crvUSD + borrowAmount;
      expectedBalances.user1.debt = expectedBalances.user1.debt + borrowAmount;
      expectedBalances.rToken.crvUSD =
        expectedBalances.rToken.crvUSD - borrowAmount;

      let user1CrvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(user1CrvUSDBalance).to.equal(expectedBalances.user1.crvUSD);
      let user1DebtBalance = await debtToken.balanceOf(user1.address);
      expect(user1DebtBalance).to.closeTo(
        expectedBalances.user1.debt,
        ethers.parseEther("0.000002")
      );

      await ethers.provider.send("evm_increaseTime", [1 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await lendingPool.connect(user1).updateState();

      await ethers.provider.send("evm_increaseTime", [364 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await lendingPool.connect(user1).updateState();

      const currentBorrowRate = await getCurrentBorrowRatePercentage(
        lendingPool
      );
      const currentLiquidityRate = await getCurrentLiquidityRatePercentage(
        lendingPool
      );

      expect(currentBorrowRate).to.be.closeTo(2.52, 0.03);
      const wadCurrentBorrowRatePercentage = ethers.parseUnits(
        currentBorrowRate.toString(),
        18
      );
      const wadCurrentLiquidityRatePercentage = ethers.parseUnits(
        currentLiquidityRate.toString(),
        18
      );

      expect(wadCurrentBorrowRatePercentage).to.be.closeTo(
        ethers.parseUnits(currentBorrowRate.toString(), 18),
        ethers.parseUnits("0.01", 18)
      );

      await lendingPool.connect(user1).updateState();
      const generatedDebt =
        (expectedBalances.user1.debt * wadCurrentBorrowRatePercentage) /
        BigInt(100 * 1e18);

      const utilizationRate = await getCurrentUtilizationRatePercentage(
        lendingPool
      );
      const totalLiquidity = await crvusd.balanceOf(rToken.target);
      const generatedInterest =
        (totalLiquidity * wadCurrentLiquidityRatePercentage) /
        BigInt(100 * 1e18);

      expect(generatedInterest).to.be.closeTo(
        ethers.parseUnits("0.25", 18),
        ethers.parseUnits("0.004", 18)
      );
      const percentInterestGenerated =
        Number(
          (generatedDebt * 100n * BigInt(1e18)) / expectedBalances.user1.debt
        ) / 1e18;
      expect(percentInterestGenerated).to.be.closeTo(currentBorrowRate, 0.03);
      expectedBalances.user1.debt = expectedBalances.user1.debt + generatedDebt;
      expectedBalances.user2.rToken =
        expectedBalances.user2.rToken + generatedInterest;

      await lendingPool.connect(user1).updateState();
      const user2RTokenBalance = await rToken.balanceOf(user2.address);

      expect(user2RTokenBalance).to.closeTo(
        expectedBalances.user2.rToken,
        ethers.parseUnits("0.01", 18)
      );
      const amountInterest = user2RTokenBalance - expectedBalances.user2.rToken;

      const repayAmount = ethers.parseEther("1");
      await crvusd.connect(user1).approve(rToken.target, repayAmount);
      await lendingPool.connect(user1).repay(repayAmount);
      await lendingPool.connect(user1).updateState();
      console.log({
        crvusd: {
          user1: ethers.formatEther(await crvusd.balanceOf(user1.address)),
          user2: ethers.formatEther(await crvusd.balanceOf(user2.address)),
          reserve: ethers.formatEther(await crvusd.balanceOf(rToken.target)),
        },
        rToken: {
          user1: ethers.formatEther(await rToken.balanceOf(user1.address)),
          user2: ethers.formatEther(await rToken.balanceOf(user2.address)),
        },
        debtToken: {
          user1: ethers.formatEther(await debtToken.balanceOf(user1.address)),
          user2: ethers.formatEther(await debtToken.balanceOf(user2.address)),
        },
      });
      expectedBalances.user1.crvUSD =
        expectedBalances.user1.crvUSD - repayAmount;
      expectedBalances.user1.debt = expectedBalances.user1.debt - repayAmount;
      expectedBalances.rToken.crvUSD =
        expectedBalances.rToken.crvUSD + repayAmount;

      user1CrvUSDBalance = await crvusd.balanceOf(user1.address);
      expect(user1CrvUSDBalance).to.be.closeTo(
        expectedBalances.user1.crvUSD,
        ethers.parseEther("0.05")
      );

      expect(await debtToken.balanceOf(user1.address)).to.be.closeTo(
        expectedBalances.user1.debt,
        ethers.parseEther("0.6")
      );
      // expect(await debtToken.balanceOf(user1.address)).to.be.closeTo(expectedBalances.user1.debt, ethers.parseEther("0.06"));
      expect(await crvusd.balanceOf(rToken.target)).to.be.gte(
        expectedBalances.rToken.crvUSD
      );
      expect(await crvusd.balanceOf(rToken.target)).to.be.lte(
        expectedBalances.rToken.crvUSD + 1n
      );

      const depositAmount = ethers.parseEther("990");

      await crvusd
        .connect(user2)
        .approve(lendingPool.target, depositAmount + ethers.parseEther("10"));
      await lendingPool.connect(user2).deposit(depositAmount);
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      await lendingPool.connect(user2).deposit(ethers.parseEther("1"));
      expectedBalances.user2.crvUSD =
        expectedBalances.user2.crvUSD - depositAmount - ethers.parseEther("10");
      expectedBalances.user2.rToken =
        expectedBalances.user2.rToken + depositAmount + ethers.parseEther("10");
      expectedBalances.rToken.crvUSD =
        expectedBalances.rToken.crvUSD +
        depositAmount +
        ethers.parseEther("10");
      expect(await crvusd.balanceOf(rToken.target)).to.be.gte(
        expectedBalances.rToken.crvUSD
      );
      expect(await crvusd.balanceOf(rToken.target)).to.be.lte(
        expectedBalances.rToken.crvUSD
      );

      expect(await rToken.balanceOf(user2.address)).to.closeTo(
        expectedBalances.user2.rToken,
        ethers.parseEther("0.01")
      );
      expect(await crvusd.balanceOf(user2.address)).to.equal(
        expectedBalances.user2.crvUSD
      );

      const user2RTokenBalanceAfterDeposit = await rToken.balanceOf(
        user2.address
      );
      expect(user2RTokenBalanceAfterDeposit).to.be.closeTo(
        depositAmount +
          ethers.parseEther("10") +
          depositedAmount +
          ethers.parseEther("0.25"),
        ethers.parseEther("0.3")
      );
      user1DebtBalance = await debtToken.balanceOf(user1.address);
      expect(user1DebtBalance).to.be.closeTo(
        borrowAmount - repayAmount,
        ethers.parseEther("0.6")
      );
      // await ethers.provider.send("evm_increaseTime", [7 * 86400]);
      // await ethers.provider.send("evm_mine");

      const generatedInterest2 =
        (expectedBalances.user1.debt * wadCurrentBorrowRatePercentage) /
        BigInt(100 * 1e18);
      const percentInterestGenerated2 =
        Number(
          (generatedInterest2 * 100n * BigInt(1e18)) /
            expectedBalances.user1.debt
        ) / 1e18;
      expect(percentInterestGenerated2).to.be.closeTo(currentBorrowRate, 0.01);
      expectedBalances.user1.debt =
        expectedBalances.user1.debt + generatedInterest2;
      expectedBalances.user2.rToken =
        expectedBalances.user2.rToken + generatedInterest2;
      expect(expectedBalances.user2.rToken).to.be.closeTo(
        expectedBalances.user2.rToken,
        ethers.parseEther("0.01")
      );

      const secondRepayAmount = ethers.parseEther("4");
      await crvusd.connect(user1).approve(rToken.target, secondRepayAmount);
      await lendingPool.connect(user1).repay(secondRepayAmount);

      expectedBalances.user1.crvUSD =
        expectedBalances.user1.crvUSD - secondRepayAmount;
      expectedBalances.user1.debt =
        expectedBalances.user1.debt - secondRepayAmount + generatedInterest2;
      expectedBalances.rToken.crvUSD =
        expectedBalances.rToken.crvUSD + secondRepayAmount;

      expect(await crvusd.balanceOf(user1.address)).to.be.closeTo(
        expectedBalances.user1.crvUSD,
        ethers.parseEther("0.3")
      );
      expect(await debtToken.balanceOf(user1.address)).to.be.closeTo(
        expectedBalances.user1.debt,
        ethers.parseEther("0.8")
      );
      expect(await crvusd.balanceOf(rToken.target)).to.be.gte(
        expectedBalances.rToken.crvUSD
      );
      expect(await crvusd.balanceOf(rToken.target)).to.be.lte(
        expectedBalances.rToken.crvUSD + 10n
      );
      const user1CrvUSDAfterSecondRepay = await crvusd.balanceOf(user1.address);

      expect(user1CrvUSDAfterSecondRepay).to.be.lessThanOrEqual(
        ethers.parseEther("1005")
      );
      expect(user1CrvUSDAfterSecondRepay).to.be.greaterThanOrEqual(
        ethers.parseEther("1004.999")
      );

      const user2RTokenBalanceAfterSecondRepay = await rToken.balanceOf(
        user2.address
      );
      expect(user2RTokenBalanceAfterSecondRepay).to.be.closeTo(
        depositAmount +
          depositedAmount +
          ethers.parseEther("10") +
          ethers.parseEther("0.25"),
        ethers.parseEther("0.1")
      );
      await lendingPool.connect(user2).withdraw(depositAmount);
      const user2RTokenBalanceAfterWithdraw = await rToken.balanceOf(
        user2.address
      );
      expect(user2RTokenBalanceAfterWithdraw).to.be.closeTo(
        depositedAmount + ethers.parseEther("10.25"),
        ethers.parseEther("0.3")
      );

      const user1DebtBalance2 = await debtToken.balanceOf(user1.address);
      await crvusd
        .connect(user1)
        .approve(rToken.target, user1DebtBalance2 + ethers.parseEther("0.3"));
      await lendingPool
        .connect(user1)
        .repay(user1DebtBalance2 + ethers.parseEther("2"));

      const user2RTokenBalanceAfter = await rToken.balanceOf(user2.address);
      expect(user2RTokenBalanceAfter).to.be.gt("2000");
      await lendingPool.connect(user1).withdrawNFT(1);

      const fullWithdraw =
        (await rToken.balanceOf(user2.address)) + ethers.parseEther("0.1");
      await lendingPool.connect(user2).withdraw(fullWithdraw);
      const user2RTokenBalanceAfterFinalWithdraw = await rToken.balanceOf(
        user2.address
      );
      expect(user2RTokenBalanceAfterFinalWithdraw).to.equal(0);
      const lendingPoolBalance = await crvusd.balanceOf(rToken.target);

      let expectedFinalReservePoolBalance = ethers.parseEther("0.0032");

      expect(lendingPoolBalance).to.closeTo(
        expectedFinalReservePoolBalance,
        ethers.parseEther("0.01")
      );

      const user1CrvUSDBalanceAfterFinalWithdraw = await crvusd.balanceOf(
        user1.address
      );
      expect(user1CrvUSDBalanceAfterFinalWithdraw).to.closeTo(
        ethers.parseEther("999.74"),
        ethers.parseEther("0.1")
      );

      const user1DebtBalanceAfterFinalWithdraw = await debtToken.balanceOf(
        user1.address
      );
      expect(user1DebtBalanceAfterFinalWithdraw).to.equal(0);

      const user2CrvUSDBalanceAfterFinalWithdraw = await crvusd.balanceOf(
        user2.address
      );
      expect(user2CrvUSDBalanceAfterFinalWithdraw).to.closeTo(
        user2InitialBalance +
          ethers.parseEther("2000") +
          ethers.parseEther("0.254"),
        ethers.parseEther("0.1")
      );

      expect(user2RTokenBalanceAfterFinalWithdraw).to.equal(0);
    });

    it("deposits in curve vault will revert with insufficient balance", async function () {
      //c for testing purposes
      /*c to run this test, deploy the mockcrvvault contract and set it as the curve vault in the lending pool. to do this, add the following line to the test script:

      const MockCrvVault = await ethers.getContractFactory("MockCrvVault");
    mockcrvvault = await MockCrvVault.deploy(crvusd.target);

    You also need to deploy the mockcrvvault I created which i have shared in the submission

      */
      await lendingPool.setCurveVault(mockcrvvault.target);

      const depositAmount = ethers.parseEther("1000");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);

      await expect(
        lendingPool.connect(user2).deposit(depositAmount)
      ).to.be.revertedWithCustomError("ERC20InsufficientBalance");
    });

    it("deposits in curve vault will revert if totalassets in curve vault is ever 0", async function () {
      //c for testing purposes
      /*c to run this test, deploy the mockcrvvault contract and set it as the curve vault in the lending pool. to do this, add the following line to the test script:

      const MockCrvVault = await ethers.getContractFactory("MockCrvVault");
    mockcrvvault = await MockCrvVault.deploy(crvusd.target);

    You also need to deploy the mockcrvvault I created which i have shared in the submission

      */
      //c allow a user to deposit in the curve vault to get largeamount of shares so when LendingPool tried to deposit, it reverts with zero shares.

      const mintAmount3 = ethers.parseEther("10000");
      await crvusd.mint(lendingPool.target, mintAmount3);

      //c create a situation where totalassets is 10000 but total supply is 0 which is the position where the ciurve vault says to return a price per share of 0
      await crvusd
        .connect(user2)
        .transfer(mockcrvvault.target, ethers.parseEther("10000"));

      const shares = await mockcrvvault.convertToShares(
        ethers.parseEther("10")
      );
      console.log("shares", shares);

      await lendingPool.setCurveVault(mockcrvvault.target);

      const depositAmount = ethers.parseEther("10");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);

      await lendingPool.connect(user2).deposit(depositAmount);

      //c STILL TRYING TO BUILD OUT THIS EXPLOIT
    });

    it("users can clear debt without full repayment", async function () {
      //c for testing purposes

      const borrowAmount = ethers.parseEther("50");

      //c on first borrow for user, the amount of debt tokens is correct as the balanceIncrease remains 0 as the if condition is not run
      await lendingPool.connect(user1).borrow(borrowAmount);

      const reservedata = await lendingPool.getAllUserData(user1.address);
      console.log(`usageindex`, reservedata.usageIndex);

      const expecteddebt = await reserveLibrary.raymul(
        reservedata.scaledDebtBalance,
        reservedata.usageIndex
      );

      console.log(`expecteddebt`, expecteddebt);

      //c note that the balanceOf function gets the actual debt by multiplying the normalized debt by the usage index. See DebtToken::balanceOf
      const debtBalance = await debtToken.balanceOf(user1.address);
      console.log("debtBalance", debtBalance);

      //c proof that the expectedamount is debt is the same as the debt balance after first deposit
      assert(expecteddebt == debtBalance);

      //c allow time to pass so that the usage index is updated
      await time.increase(365 * 24 * 60 * 60);

      //c on second borrow for user, the amount of debt tokens differs from the users scaleddebtbalance in the LendingPool contract as the balanceIncrease is not 0 as the if condition is run
      await lendingPool.connect(user1).borrow(borrowAmount);

      const reservedata1 = await lendingPool.getAllUserData(user1.address);
      console.log(`secondborrowusageindex`, reservedata1.usageIndex);

      const secondborrowexpecteddebt = await reserveLibrary.raymul(
        reservedata1.scaledDebtBalance,
        reservedata1.usageIndex
      );

      console.log(reservedata1.scaledDebtBalance);

      console.log(`secondborrowexpecteddebt`, secondborrowexpecteddebt);
      const secondborrowdebtBalance = await debtToken.balanceOf(user1.address);

      //c proof that the expecteddebt is now less than the debt balance after second borrow which shows inconsistency
      assert(secondborrowdebtBalance > secondborrowexpecteddebt);

      //c user will be able to repay their full debt but they will still have debt tokens leftover which shows the inconsistency between scaled debt in the lending pool and the debt token which means that a user can create a scenario where the LendingPool thinks that user has cleared their debt when in reality, they still have debt according to the debt token contract
      await lendingPool.connect(user1).repay(secondborrowexpecteddebt);
      const reservedata2 = await lendingPool.getAllUserData(user1.address);
      console.log(`userscaleddebt`, reservedata2.scaledDebtBalance);

      const postrepayexpecteddebt = await reserveLibrary.raymul(
        reservedata2.scaledDebtBalance,
        reservedata2.usageIndex
      );

      const postrepaydebtBalance = await debtToken.balanceOf(user1.address);
      console.log("postrepaydebtBalance", postrepaydebtBalance);

      assert(postrepaydebtBalance > postrepayexpecteddebt);
      assert(postrepayexpecteddebt == 0);
    });

    it("underflow occurs in repay", async function () {
      //c for testing purposes

      const borrowAmount = ethers.parseEther("50");

      //c on first borrow for user, the amount of debt tokens is correct as the balanceIncrease remains 0 as the if condition is not run
      await lendingPool.connect(user1).borrow(borrowAmount);

      const reservedata = await lendingPool.getAllUserData(user1.address);
      console.log(`usageindex`, reservedata.usageIndex);

      const expecteddebt = await reserveLibrary.raymul(
        reservedata.scaledDebtBalance,
        reservedata.usageIndex
      );

      console.log(`expecteddebt`, expecteddebt);
      //c note that the balanceOf function gets the actual debt by multiplying the normalized debt by the usage index. See DebtToken::balanceOf
      const debtBalance = await debtToken.balanceOf(user1.address);
      console.log("debtBalance", debtBalance);

      //c proof that the expectedamount is debt is the same as the debt balance after first deposit
      assert(expecteddebt == debtBalance);

      //c allow time to pass so that the usage index is updated
      await time.increase(365 * 24 * 60 * 60);

      //c on second borrow for user, the amount of debt tokens is inflated as the balanceIncrease is not 0 as the if condition is run
      await lendingPool.connect(user1).borrow(borrowAmount);

      const reservedata1 = await lendingPool.getAllUserData(user1.address);
      console.log(`secondborrowusageindex`, reservedata1.usageIndex);

      const secondborrowexpecteddebt = await reserveLibrary.raymul(
        reservedata1.scaledDebtBalance,
        reservedata1.usageIndex
      );

      console.log(reservedata1.scaledDebtBalance);

      console.log(`secondborrowexpecteddebt`, secondborrowexpecteddebt);
      const secondborrowdebtBalance = await debtToken.balanceOf(user1.address);
      console.log("secondborrowdebtBalance", secondborrowdebtBalance);

      //c proof that the expecteddebt is now less than the debt balance after second borrow which shows discrepancy and leads to underflow
      assert(secondborrowdebtBalance > secondborrowexpecteddebt);

      //c when user attempts to repay their debt according to the debt token contract balanceOf function, there will be an underflow as the expected debt is less than the debt balance
      await expect(lendingPool.connect(user1).repay(secondborrowdebtBalance)).to
        .be.reverted;
    });

    it("user can borrow more than their collateral", async function () {
      //c for testing purposes
      const userCollateral = await lendingPool.getUserCollateralValue(
        user1.address
      );
      console.log("userCollateral", userCollateral);

      const borrowAmount = userCollateral + ethers.parseEther("20");
      console.log("borrowAmount", borrowAmount);
      await lendingPool.connect(user1).borrow(borrowAmount);
      assert(borrowAmount > userCollateral);
    });

    it("user can withdraw their nft when in debt", async function () {
      //c for testing purposes

      await raacHousePrices.setHousePrice(2, ethers.parseEther("100"));

      const amountToPay = ethers.parseEther("100");

      //c mint nft for user1. this mints an extra nft for the user. in the before each of the initial describe in LendingPool.test.js, user1 already has an nft
      const tokenId = 2;
      await token.mint(user1.address, amountToPay);

      await token.connect(user1).approve(raacNFT.target, amountToPay);

      await raacNFT.connect(user1).mint(tokenId, amountToPay);

      //c depositnft for user1
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);

      //c user borrows debt
      const borrowAmount = ethers.parseEther("110");
      console.log("borrowAmount", borrowAmount);
      await lendingPool.connect(user1).borrow(borrowAmount);

      //c user can withdraw one of their nfts which makes their debt worth more than their collateral
      await lendingPool.connect(user1).withdrawNFT(tokenId);

      const userCollateral = await lendingPool.getUserCollateralValue(
        user1.address
      );
      console.log("userCollateral", userCollateral);

      const user1debt = await debtToken.balanceOf(user1.address);
      console.log("user1debt", user1debt);

      assert(user1debt > userCollateral);
    });

    it("user can repay their debt after grace period ends and liquidation has been initiated", async function () {
      //c for testing purposes

      //c for testing purposes
      const userCollateral = await lendingPool.getUserCollateralValue(
        user1.address
      );
      console.log("userCollateral", userCollateral);

      //c user borrows 90% of their collateral which puts their health factor below 1 and qualifies them for liquidation
      const borrowAmount = ethers.parseEther("90");
      console.log("borrowAmount", borrowAmount);
      await lendingPool.connect(user1).borrow(borrowAmount);

      //c calculate user's health factor
      const healthFactor = await lendingPool.calculateHealthFactor(
        user1.address
      );
      console.log("healthFactor", healthFactor);
      assert(
        healthFactor <
          (await lendingPool.BASE_HEALTH_FACTOR_LIQUIDATION_THRESHOLD())
      );

      //c allow grace period to pass
      await time.increase(4 * 24 * 60 * 60);

      const reservedata1 = await lendingPool.getAllUserData(user1.address);
      const userscaleddebtprerepay = reservedata1.scaledDebtBalance;
      console.log(`userscaleddebt`, userscaleddebtprerepay);

      //c someone initiates liquidation
      await lendingPool.connect(user2).initiateLiquidation(user1.address);

      //c since grace period has passed and user has not been liquidated, they can repay their debt
      await lendingPool.connect(user1).repay(borrowAmount);
      const reservedata = await lendingPool.getAllUserData(user1.address);
      const userscaleddebt = reservedata.scaledDebtBalance;
      console.log(`userscaleddebt`, userscaleddebt);

      assert(userscaleddebt < userscaleddebtprerepay);
    });

    it("rescueTokenDOS", async function () {
      //c for testing purposes
      await raacHousePrices.setHousePrice(3, ethers.parseEther("100"));

      const amountToPay = ethers.parseEther("100");

      //c mint nft for user1. this mints an extra nft for the user. in the before each of the initial describe in LendingPool.test.js, user1 already has an nft
      const tokenId = 3;
      await token.mint(rejectERC721.target, amountToPay);

      /*c for this test to work, you need to deploy the following contract
      //SDPX-license-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IRAACNFT} from "contracts/interfaces/core/tokens/IRAACNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectERC721 is IERC721Receiver {
    address public rAACNFT;
    address public crvusd;
    error RejectERC721Error();

    constructor(address _raacNFT, address _crvusd) {
        rAACNFT = _raacNFT;
        crvusd = _crvusd;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 token,
        bytes calldata data
    ) external view override returns (bytes4) {
        if (from != address(0)) {
            revert RejectERC721Error();
        }

        return this.onERC721Received.selector;
    }

    function mintNFT(uint256 tokenId, uint256 amounttoPay) external {
        IERC20(crvusd).approve(rAACNFT, amounttoPay);
        IRAACNFT(rAACNFT).mint(tokenId, amounttoPay);
    }

    function transferNFT(address to, uint256 tokenId) external {
        IRAACNFT(rAACNFT).transferFrom(address(this), to, tokenId);
    }
}

      then deploy the contract in the initial desribe with the following lines:
      const RejectERC721 = await ethers.getContractFactory("RejectERC721");
      rejectERC721 = await RejectERC721.deploy(raacNFT.target, crvusd.target);
      */

      //c if a user mistakenly transfers an nft to the lending pool which is actually the main token that the lending pool contract uses, there will be no way to recover that nft. the protocol doesnt need to focus on how having a rescuetoken function that doesnt focus on nfts as the nfts are extremely valuable so it makes sense to have guards in place to prevent users from losing their nfts
      await rejectERC721.connect(user1).mintNFT(tokenId, amountToPay);
      await rejectERC721
        .connect(user1)
        .transferNFT(lendingPool.target, tokenId);
    });

    it("rescueTokenERC777", async function () {
      //c for testing purposes

      await ERC777Token.connect(owner).transfer(
        attacker.target,
        ethers.parseEther("100")
      );
      await attacker.sendToken(lendingPool.target, ethers.parseEther("100"));

      await expect(
        lendingPool.rescueToken(
          ERC777Token.target,
          attacker.target,
          ethers.parseEther("100")
        )
      ).to.be.revertedWithCustomError("RejectERC777Error");
    });

    it("deposit function doesnt update liquidity rate iteration 1", async function () {
      //c for testing purposes . DO NOT DELETE. THE EXPLANATION IN THIS TEST IS INVALUABLE

      const reserve = await lendingPool.reserve();
      console.log("reserve", reserve.lastUpdateTimestamp);

      const depositAmount = ethers.parseEther("100");
      await lendingPool.connect(user1).deposit(depositAmount);
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      //c user deposits tokens into lending pool to get rtokens

      await lendingPool.connect(user1).deposit(depositAmount);

      const reserve1 = await lendingPool.reserve();
      console.log("reservetimestamp", reserve1.lastUpdateTimestamp);
      console.log("reservetimedelta", reserve1.timeDelta);
      console.log("reservecummulatedinterest", reserve1.cumulatedInterest);

      /*c heres the issue. when a deposit is first made, the currentliquidityrate is 0. this means that whenever someone deposits and ReserveLibrary::updateReserveInterests is called, which calls ReserveLibrary::calculateLiquidityIndex which also calls ReserveLibrary::calculateLinearInterest, the liquidity index will not change no matter how many deposits there are. to see this, i added new variables to these function in the reserve library contract and logged them. I did this because i found out that no matter how much I deposited and how much time had passed, the liquidity index stayed the same which means that the rtokens were not scaled. When i tried to then borrow first before depositing, i saw that the liquidity index then changed which made me look into what the differences between deposit and borrow functions were and I noticed that borrow called ReserveLibrary::updateInterestRatesAndLiquidity which calls a key function called ReserveLibrary::calculateLiquidityRate which is what updates the liquidity index. ReserveLibrary::updateInterestRatesAndLiquidity is also called when a deposit is made but the ReserveLibrary::calculateLiquidityIndex calls has the following line 

       if (totalDebt < 1) {
            return 0;
        }

        which means that the liquidity index will not change if there is no debt in the system. This is why the liquidity index will not change no matter how many deposits you make

      */

      const ratedata = await lendingPool.rateData();
      console.log("ratedata", ratedata.currentLiquidityRate);

      const reservedata = await lendingPool.getAllUserData(user1.address);
      console.log(`liqindex`, reservedata.liquidityIndex);
    });

    it("deposit function doesnt update liquidity rate iteration 2", async function () {
      //c for testing purposes . IMPORTANT TEST TO CHECK UNDERFLOW. MUST KEEP

      await raacHousePrices.setHousePrice(2, ethers.parseEther("100"));

      const amountToPay = ethers.parseEther("100");

      //c mint nft for user1. this mints an extra nft for the user. in the before each of the initial describe in LendingPool.test.js, user1 already has an nft
      const tokenId = 2;
      await token.mint(user1.address, amountToPay);

      await token.connect(user1).approve(raacNFT.target, amountToPay);

      await raacNFT.connect(user1).mint(tokenId, amountToPay);

      //c depositnft for user1
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);

      await lendingPool.setProtocolFeeRate(ethers.parseEther("100000000"));

      //c user 1 borrows to update the liquidity and borrow rates
      const depositAmount = ethers.parseEther("190");
      await lendingPool.connect(user1).borrow(depositAmount);
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      const reserve = await lendingPool.getAllUserData(user1.address);
      const utilizationrate = await lendingPool.calculateUtilizationRate(
        reserve.totalLiquidity,
        reserve.totalUsage
      );
      console.log("utilizationrate", utilizationrate);

      //c user deposits tokens into lending pool to get rtokens

      await lendingPool.connect(user1).deposit(ethers.parseEther("1000"));

      //c user has deposited now so we expect the liquidity rate and the borrow rate to change as the utilization rate has changed which affects both of these calculations.
      const postdepositreserve = await lendingPool.getAllUserData(
        user1.address
      );
      const postdepositutilizationrate =
        await lendingPool.calculateUtilizationRate(
          postdepositreserve.totalLiquidity,
          postdepositreserve.totalUsage
        );
      console.log("postdepositutilizationrate", postdepositutilizationrate);

      const ratedata = await lendingPool.rateData();

      const expectedusagerate = await lendingPool.calculateBorrowRate(
        ratedata.primeRate,
        ratedata.baseRate,
        ratedata.optimalRate,
        ratedata.maxRate,
        ratedata.optimalUtilizationRate,
        postdepositutilizationrate
      );
      console.log("expectedusagerate", expectedusagerate);

      const expectedliquidityrate = await lendingPool.calculateLiquidityRate(
        postdepositutilizationrate,
        expectedusagerate,
        ratedata.protocolFeeRate,
        reserve.totalUsage
      );
      console.log("expectedliquidityrate", expectedliquidityrate);

      const grossliq = await lendingPool.grossLiquidityRate();
      const protocolfeerate = await lendingPool.protocolFeeAmount();

      console.log("grossliq", grossliq);
      console.log("protocolfeerate", protocolfeerate);
    });

    it("transfering rtokens devalues them via double scaling issue", async function () {
      //c for testing purposes
      const reserve = await lendingPool.reserve();
      console.log("reserve", reserve.lastUpdateTimestamp);

      //c first borrow that updates liquidity index and interest rates as deposits dont update it
      const depositAmount = ethers.parseEther("100");
      await lendingPool.connect(user1).borrow(depositAmount);
      await time.increase(5000 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      //c user deposits tokens into lending pool to get rtokens

      await lendingPool.connect(user1).deposit(depositAmount);

      const reservedata = await lendingPool.getAllUserData(user1.address);
      console.log(`liqindex`, reservedata.liquidityIndex);

      //c get scaled rtokenbalance of user1
      const user1RTokenBalance = await rToken.scaledBalanceOf(user1.address);
      console.log("user1RTokenBalance", user1RTokenBalance);

      //c get user2 token balance before transfer
      const pretransferuser2RTokenBalance = await rToken.scaledBalanceOf(
        user2.address
      );
      console.log(
        "pretransferuser2RTokenBalance",
        pretransferuser2RTokenBalance
      );

      //c proof that rtokens are scaled upon minting
      assert(user1RTokenBalance < depositAmount);

      const transferAmount = ethers.parseEther("50");
      //c user transfers rtoken to user2
      await rToken.connect(user1).transfer(user2.address, transferAmount);

      //c get rtokenbalance of user2
      const user2RTokenBalance = await rToken.scaledBalanceOf(user2.address);
      console.log("user2RTokenBalance", user2RTokenBalance);

      //c get amount transferred to user 2
      const amountTransferred =
        user2RTokenBalance - pretransferuser2RTokenBalance;
      console.log("amountTransferred", amountTransferred);

      //c single scaled transfer amount

      /*c IMPORTANT: for this test to work, first go to reservelibrarymock.sol and include the following functions:
      function raymul(
        uint256 val1,
        uint256 val2
    ) external pure returns (uint256) {
        return val1.rayMul(val2);
    }

     function raydiv(
        uint256 val1,
        uint256 val2
    ) external pure returns (uint256) {
        return val1.rayDiv(val2);
    }
       
       
       then deploy the contract with the following lines:
        const reservelibrary = await ethers.getContractFactory(
      "ReserveLibraryMock"
    );
    reserveLibrary = await reservelibrary.deploy();
    */
      const normalizedincome = await lendingPool.getNormalizedIncome();
      console.log("normalizedincome", normalizedincome);

      const singlescaledtamount = await reserveLibrary.raydiv(
        transferAmount,
        normalizedincome
      );

      const amount1 = await rToken.amount1();
      console.log("amount1", amount1);

      //c proof that rtokens are double scaled upon transfer further devauling them
      assert(amountTransferred < singlescaledtamount);

      //c when the amount is transferred to the user, the actual amount does not equal the amount transferred which shows that the rtokens are double scaled
      const amounttransferredunscaled = await reserveLibrary.raymul(
        amountTransferred,
        normalizedincome
      );

      assert(amounttransferredunscaled < transferAmount);
    });

    it("where does interest come from if borrowers dont repay?", async function () {
      //c for testing purposes
      const reserve = await lendingPool.reserve();
      console.log("reserve", reserve.lastUpdateTimestamp);

      await raacHousePrices.setHousePrice(2, ethers.parseEther("1000"));

      const amountToPay = ethers.parseEther("1000");

      //c mint nft for user2
      const tokenId = 2;
      await token.mint(user2.address, amountToPay);

      await token.connect(user2).approve(raacNFT.target, amountToPay);

      await raacNFT.connect(user2).mint(tokenId, amountToPay);

      //c depositnft for user2
      await raacNFT.connect(user2).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user2).depositNFT(tokenId);

      //c first borrow that updates liquidity index and interest rates as deposits dont update it
      const depositAmount = ethers.parseEther("100");
      await lendingPool.connect(user2).borrow(depositAmount);
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      //c make sure rtoken contract has no assets before transfer
      const rtokenassetbal = await token.balanceOf(rToken.target);

      await lendingPool.connect(user2).withdraw(rtokenassetbal);

      //c user deposits tokens into lending pool to get rtokens

      await lendingPool.connect(user1).deposit(depositAmount);

      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      await lendingPool.updateState(); //bug if a user checks their balance after time has passed without calling updateState(), it will display their amount without the accrued interest

      //c a year has passed and user now wants to withdraw their assets and accrue the interest they have been promised. This is what the docs say "Users that have crvUSD can participate by depositing their crvUSD to the lending pool allowing them to be used for the borrows described above. By doing so, user will receives a RToken that represents such deposit + any accrued interest.". This means at any point, i should be able to redeem my assets and get myy original assets + all my accrued interest which is not the case as I will show

      const user1RTokenBalance = await rToken.balanceOf(user1.address);
      console.log("user1RTokenBalance", user1RTokenBalance);

      const rtokenassetbalprewithdraw = await token.balanceOf(rToken.target);
      console.log("rtokenassetbalprewithdraw", rtokenassetbalprewithdraw);

      assert(user1RTokenBalance > depositAmount);

      await expect(lendingPool.connect(user1).withdraw(user1RTokenBalance)).to
        .be.reverted;
    });

    it("if updateState function is not called, a user's balance is not correctly reflected due to reserve.liquidityIndex staleness", async function () {
      //c for testing purposes

      //c first borrow that updates liquidity index and interest rates as deposits dont update it
      const depositAmount = ethers.parseEther("100");
      await lendingPool.connect(user2).borrow(depositAmount);
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      //c user deposits tokens into lending pool to get rtokens
      await lendingPool.connect(user1).deposit(depositAmount);

      //c time passes and user1 wants to check their balance to see how much interest they have accrued
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");

      //c user1 checks their balance and finds no accrued interest as reserve.liquidityIndex is stale
      const prestateupdateuser1RTokenBalance = await rToken.balanceOf(
        user1.address
      );
      console.log(
        "prestateupdateuser1RTokenBalance",
        prestateupdateuser1RTokenBalance
      );

      await lendingPool.updateState();
      const expecteduser1RTokenBalance = await rToken.balanceOf(user1.address);
      console.log("expecteduser1RTokenBalance", expecteduser1RTokenBalance);

      assert(prestateupdateuser1RTokenBalance < expecteduser1RTokenBalance);
    });
  });

  describe("Full sequence", function () {
    beforeEach(async function () {
      const initialBalanceOfRToken = await crvusd.balanceOf(rToken.target);

      const depositAmount = ethers.parseEther("1000");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user2).deposit(depositAmount);
      // mine 1 day update state
      await ethers.provider.send("evm_increaseTime", [1 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await lendingPool.connect(user2).updateState();
      const tokenId = 1;
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);

      const borrowAmount = ethers.parseEther("80");
      await lendingPool.connect(user1).borrow(borrowAmount);

      await crvusd
        .connect(user2)
        .approve(lendingPool.target, ethers.parseEther("1000"));
      await crvusd
        .connect(owner)
        .approve(lendingPool.target, ethers.parseEther("1000"));

      await lendingPool.connect(user2).withdraw(depositAmount);
      const depositedAmount = ethers.parseEther("1000");
      const user2RTokenBalanceAfterWithdraw = await rToken.balanceOf(
        user2.address
      );

      expect(user2RTokenBalanceAfterWithdraw).to.be.closeTo(
        depositedAmount,
        ethers.parseEther("0.3")
      );

      const user1DebtBalance2 = await debtToken.balanceOf(user1.address);
      await crvusd
        .connect(user1)
        .approve(rToken.target, user1DebtBalance2 + ethers.parseEther("0.3"));
      await lendingPool
        .connect(user1)
        .repay(user1DebtBalance2 + ethers.parseEther("1"));

      const user1DebtAfterRepay2 = await debtToken.balanceOf(user1.address);
      expect(user1DebtAfterRepay2).to.be.lte(0); // Should be zero

      const user2RTokenBalanceAfter = await rToken.balanceOf(user2.address);
      expect(user2RTokenBalanceAfter).to.be.gt("2000");

      await lendingPool.connect(user1).withdrawNFT(1);

      const rTokenBeforeFullWithdraw = await rToken.balanceOf(user2.address);
      const fullWithdraw = rTokenBeforeFullWithdraw + ethers.parseEther("20.2");

      await lendingPool.connect(user2).withdraw(fullWithdraw);
      const user2RTokenBalanceAfterFinalWithdraw = await rToken.balanceOf(
        user2.address
      );

      expect(user2RTokenBalanceAfterFinalWithdraw).to.equal(0);

      const lendingPoolBalance = await crvusd.balanceOf(rToken.target);
      // expect(initialBalanceOfRToken).to.equal(ethers.parseEther("2000"));

      let expectedFinalReservePoolBalance =
        initialBalanceOfRToken -
        ethers.parseEther("80") + // User1 borrow
        ethers.parseEther("1000") - // User2 additional deposit
        // + ethers.parseEther("80")      // User1 second repay
        ethers.parseEther("1000") + // User2 first withdrawal
        user1DebtBalance2 - // User1 final repay (actual debt balance)
        // + ethers.parseEther("20")     // User3 deposit
        rTokenBeforeFullWithdraw + // User2 final withdrawal
        ethers.parseEther("0.0000002"); // difference between linear and compounded interest + rounding + other reserve
      // + ethers.parseEther("0.000000000024778654"); // difference between linear and compounded interest + rounding + other reserve
      // Assert the expected balance
      expect(lendingPoolBalance).to.closeTo(
        expectedFinalReservePoolBalance,
        ethers.parseEther("0.00001")
      );

      // Display user1's crvUSD balance
      const user1CrvUSDBalanceAfterFinalWithdraw = await crvusd.balanceOf(
        user1.address
      );
      expect(user1CrvUSDBalanceAfterFinalWithdraw).to.closeTo(
        ethers.parseEther("999.99"),
        ethers.parseEther("0.1")
      );

      // Display user1's debt balance
      const user1DebtBalanceAfterFinalWithdraw = await debtToken.balanceOf(
        user1.address
      );
      expect(user1DebtBalanceAfterFinalWithdraw).to.equal(0);

      // Display user2's crvUSD balance
      const user2CrvUSDBalanceAfterFinalWithdraw = await crvusd.balanceOf(
        user2.address
      );
      expect(user2CrvUSDBalanceAfterFinalWithdraw).to.gte(
        ethers.parseEther("1000")
      );
      expect(user2RTokenBalanceAfterFinalWithdraw).to.equal(0);
    });
    it("should transfer accrued dust correctly", async function () {
      // create obligations

      const predonationassetAmount = await token.balanceOf(rToken.target);
      console.log("assetAmount", predonationassetAmount.toString());
      await crvusd
        .connect(user1)
        .approve(lendingPool.target, ethers.parseEther("100"));
      await lendingPool.connect(user1).deposit(ethers.parseEther("100"));

      // Calculate dust amount
      const dustAmount = await rToken.calculateDustAmount();
      console.log("Dust amount:", dustAmount);

      // Set up recipient and transfer dust
      const dustRecipient = owner.address;
      // TODO: Ensure dust case - it is 0n a lot. (NoDust())
      if (dustAmount !== 0n) {
        await lendingPool
          .connect(owner)
          .transferAccruedDust(dustRecipient, dustAmount);

        // Withdraw initial deposit
        await lendingPool.connect(user1).withdraw(ethers.parseEther("100"));

        const dustAmountPostWithdraw = await rToken.calculateDustAmount();
        console.log({ dustAmountPostWithdraw });
      }
    });

    it("dust amount precision error", async function () {
      // create obligations

      const predonationassetAmount = await token.balanceOf(rToken.target);
      console.log("assetAmount", predonationassetAmount.toString());

      await crvusd
        .connect(user1)
        .approve(lendingPool.target, ethers.parseEther("100"));
      await lendingPool.connect(user1).deposit(ethers.parseEther("100"));

      //c i donate 50 crvusd to the lending pool which should be considered as dust
      const dustTransfer = ethers.parseEther("50");
      await token.connect(user2).transfer(rToken.target, dustTransfer);

      //c allow some time to pass for liquidity index to update and then update state
      await time.increase(365 * 24 * 60 * 60);
      await ethers.provider.send("evm_mine");
      await lendingPool.updateState();

      // Calculate dust amount
      const dustAmount = await rToken.calculateDustAmount();
      console.log("Dust amount:", dustAmount.toString());

      // Set up recipient and transfer dust
      const dustRecipient = owner.address;
      // TODO: Ensure dust case - it is 0n a lot. (NoDust())
      if (dustAmount !== 0n) {
        await lendingPool
          .connect(owner)
          .transferAccruedDust(dustRecipient, dustAmount);
      }

      const normIncome = await lendingPool.getNormalizedIncome();
      console.log("normIncome", normIncome.toString());

      const assetAmount = await token.balanceOf(rToken.target);
      console.log("assetAmount", assetAmount.toString());

      const totalSupply = await rToken.totalSupply();
      console.log("totalSupply", totalSupply.toString());

      //c after dust is transferred, the dust amount should be 0 but due to precision and rounding errors, the dust amount is positive
      const newDustAmount = await rToken.calculateDustAmount();
      console.log("newdustamount", newDustAmount.toString());

      //c since the calcuatedustamount calculation is flawed, if user2 transfers more dust to the contract, the new dust amount will be greater than the previous dust amount for the same amount of dust transferred
      await token.connect(user2).transfer(rToken.target, dustTransfer);
      const newDustAmount1 = await rToken.calculateDustAmount();
      console.log("dustamount1", newDustAmount1.toString());
      assert(newDustAmount1 > newDustAmount);

      await lendingPool
        .connect(owner)
        .transferAccruedDust(dustRecipient, newDustAmount1);

      const newDustAmount2 = await rToken.calculateDustAmount();
      console.log("newdustamount2", newDustAmount2.toString());

      await lendingPool
        .connect(owner)
        .transferAccruedDust(dustRecipient, newDustAmount2);
    });

    it("liquidity isnt rebalanced during liquidation or repayment", async function () {
      const initialBalanceOfRToken = await crvusd.balanceOf(rToken.target);
      const depositAmount = ethers.parseEther("1000");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user2).deposit(depositAmount);
      // mine 1 day update state
      await ethers.provider.send("evm_increaseTime", [1 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await lendingPool.connect(user2).updateState();
      const tokenId = 1;
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);

      const borrowAmount = ethers.parseEther("80");
      await lendingPool.connect(user1).borrow(borrowAmount);

      await crvusd
        .connect(user2)
        .approve(lendingPool.target, ethers.parseEther("1000"));
      await crvusd
        .connect(owner)
        .approve(lendingPool.target, ethers.parseEther("1000"));

      await lendingPool.connect(user2).withdraw(depositAmount);
      const depositedAmount = ethers.parseEther("1000");
      const user2RTokenBalanceAfterWithdraw = await rToken.balanceOf(
        user2.address
      );
      expect(user2RTokenBalanceAfterWithdraw).to.be.closeTo(
        depositedAmount,
        ethers.parseEther("0.3")
      );
    });

    it("user cannot withdraw deposited amount once borrowed", async function () {
      //c for testing purposes

      const initialBalanceOfRToken = await crvusd.balanceOf(rToken.target);
      console.log("initialBalanceOfRToken", initialBalanceOfRToken);

      await raacHousePrices.setHousePrice(2, ethers.parseEther("1000"));

      const amountToPay = ethers.parseEther("1000");

      //c mint nft for user2
      const tokenId = 2;
      await token.mint(user2.address, amountToPay);

      await token.connect(user2).approve(raacNFT.target, amountToPay);

      await raacNFT.connect(user2).mint(tokenId, amountToPay);

      //c depositnft for user2
      await raacNFT.connect(user2).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user2).depositNFT(tokenId);

      //c deposit action to compare rtokenassetbalance and totalliquidity

      const depositAmount = ethers.parseEther("1000");
      await crvusd.mint(user1.address, ethers.parseEther("0.1"));
      await crvusd.connect(user1).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user1).deposit(depositAmount);

      // mine 1 day update state
      await ethers.provider.send("evm_increaseTime", [1 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await lendingPool.connect(user2).updateState();

      const borrowAmount = ethers.parseEther("800");
      await lendingPool.connect(user2).borrow(borrowAmount);

      await crvusd
        .connect(user2)
        .approve(lendingPool.target, ethers.parseEther("1000"));
      await crvusd
        .connect(owner)
        .approve(lendingPool.target, ethers.parseEther("1000"));

      //c user 1 tries to withdraw half of what they deposited but they wont be able to because rtoken contract doesnt have balance to cover the withdrawal
      await expect(
        lendingPool.connect(user1).withdraw(depositAmount / 2)
      ).to.be.revertedWithCustomError("ERC20InsufficientBalance");
      //bug when a user deposits an nft and borrows collateral from the r token contract, it stops the user who deposited from being able to withdraw their full amount which is a DOS and not supposed to be the case as there is no code in lendingpool that is meant to restrict the user from withdrawing their full amount

      //c if you look in the beforeEach of the "full sequence" describe block , you will see that user2 is able to deposit and then withdraw what they deposited. This is because in the first beforeeach of this script, user 2 makes an initial deposit of 1000 into this lending pool sowhen they withdraw, they are only withdrawing half of what they deposited. you can see this by searching for deposit in this file and looking at the first instance.

      //c you will also see in the beforeEach of the "full sequence" describe block that user 2 withdraws again but they are able to withdraw their full amount this time and this is because user 1 repaid their debt before user 2 withdrew again. the bug occurs in this test when user 1 deposits assets and user 2 comes in and uses their nft to borrow assets from the rtoken contract. this stops user 1 from being able to withdraw their full amount which cant be right because as long as there are no new deposits, or user2 is not liquidated, then user1 cannot withdraw their funds they sent into the contract
    });
  });

  describe("Liquidation", function () {
    beforeEach(async function () {
      // User2 deposits into the reserve pool to provide liquidity
      const depositAmount = ethers.parseEther("1000");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user2).deposit(depositAmount);

      // User1 deposits NFT and borrows
      const tokenId = 1;
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await lendingPool.connect(user1).depositNFT(tokenId);

      const borrowAmount = ethers.parseEther("80");
      await lendingPool.connect(user1).borrow(borrowAmount);

      // Users approve crvUSD for potential transactions
      await crvusd
        .connect(user2)
        .approve(lendingPool.target, ethers.parseEther("1000"));
      await crvusd
        .connect(owner)
        .approve(lendingPool.target, ethers.parseEther("1000"));
    });

    it("should allow initiation of liquidation when loan is undercollateralized", async function () {
      // Decrease house price to trigger liquidation
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await raacHousePrices.setHousePrice(1, ethers.parseEther("90"));
      // Attempt to initiate liquidation
      await expect(
        lendingPool.connect(user2).initiateLiquidation(user1.address)
      )
        .to.emit(lendingPool, "LiquidationInitiated")
        .withArgs(user2.address, user1.address);

      // Verify that the user is under liquidation
      expect(await lendingPool.isUnderLiquidation(user1.address)).to.be.true;

      // Verify that the user cannot withdraw NFT while under liquidation
      await expect(
        lendingPool.connect(user1).withdrawNFT(1)
      ).to.be.revertedWithCustomError(
        lendingPool,
        "CannotWithdrawUnderLiquidation"
      );

      // Verify the liquidation start time is set
      const liquidationStartTime = await lendingPool.liquidationStartTime(
        user1.address
      );
      expect(liquidationStartTime).to.be.gt(0);

      // Verify the health factor is below the liquidation threshold
      const healthFactor = await lendingPool.calculateHealthFactor(
        user1.address
      );
      const healthFactorLiquidationThreshold =
        await lendingPool.healthFactorLiquidationThreshold();
      expect(healthFactor).to.be.lt(healthFactorLiquidationThreshold);
    });

    it("should allow the user to close liquidation within grace period", async function () {
      // Decrease house price and initiate liquidation
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await raacHousePrices.setHousePrice(1, ethers.parseEther("90"));
      await lendingPool.connect(user2).initiateLiquidation(user1.address);

      // User1 repays the debt
      const userDebt = await lendingPool.getUserDebt(user1.address);
      await crvusd
        .connect(user1)
        .approve(lendingPool.target, userDebt + ethers.parseEther("1"));
      await lendingPool.connect(user1).repay(userDebt + ethers.parseEther("1"));

      // User1 closes the liquidation
      await expect(lendingPool.connect(user1).closeLiquidation())
        .to.emit(lendingPool, "LiquidationClosed")
        .withArgs(user1.address);

      // Verify that the user is no longer under liquidation
      expect(await lendingPool.isUnderLiquidation(user1.address)).to.be.false;
      // Verify that the user can now withdraw their NFT
      await expect(lendingPool.connect(user1).withdrawNFT(1))
        .to.emit(lendingPool, "NFTWithdrawn")
        .withArgs(user1.address, 1);

      // Verify that the NFT is now owned by user1
      expect(await raacNFT.ownerOf(1)).to.equal(user1.address);

      // Verify that the user's account is cleaned
      const userData = await lendingPool.userData(user1.address);
      expect(userData.scaledDebtBalance).to.equal(0);
      expect(userData.nftTokenIds).to.be.equal(undefined);

      // Double-check that the user has no remaining debt
      const userClosedLiquidationDebt = await lendingPool.getUserDebt(
        user1.address
      );
      expect(userClosedLiquidationDebt).to.equal(0);

      // Verify that the user's health factor is now at its maximum (type(uint256).max)
      const healthFactor = await lendingPool.calculateHealthFactor(
        user1.address
      );
      expect(healthFactor).to.equal(ethers.MaxUint256);
    });

    it("should allow Stability Pool to close liquidation after grace period", async function () {
      // Decrease house price and initiate liquidation
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await raacHousePrices.setHousePrice(1, ethers.parseEther("90"));
      await lendingPool.connect(user2).initiateLiquidation(user1.address);

      // Advance time beyond grace period (72 hours)
      await ethers.provider.send("evm_increaseTime", [72 * 60 * 60 + 1]);
      await ethers.provider.send("evm_mine");

      // Fund the stability pool with crvUSD
      await crvusd
        .connect(owner)
        .mint(owner.address, ethers.parseEther("1000"));

      // Set Stability Pool address (using owner for this test)
      await lendingPool.connect(owner).setStabilityPool(owner.address);

      await expect(
        lendingPool.connect(owner).finalizeLiquidation(user1.address)
      ).to.emit(lendingPool, "LiquidationFinalized");

      // Verify that the user is no longer under liquidation
      expect(await lendingPool.isUnderLiquidation(user1.address)).to.be.false;

      // Verify that the NFT has been transferred to the Stability Pool
      expect(await raacNFT.ownerOf(1)).to.equal(owner.address);

      // Verify that the user's debt has been repaid
      const userClosedLiquidationDebt = await lendingPool.getUserDebt(
        user1.address
      );
      expect(userClosedLiquidationDebt).to.equal(0);

      // Verify that the user's health factor is now at its maximum (type(uint256).max)
      const healthFactor = await lendingPool.calculateHealthFactor(
        user1.address
      );
      expect(healthFactor).to.equal(ethers.MaxUint256);
    });

    it("should prevent non-owner from closing liquidation within grace period", async function () {
      // Decrease house price and initiate liquidation
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await raacHousePrices.setHousePrice(1, ethers.parseEther("90"));
      await lendingPool.connect(user2).initiateLiquidation(user1.address);

      // Attempt to close liquidation by non-owner (user2)
      await expect(
        lendingPool.connect(user2).closeLiquidation()
      ).to.be.revertedWithCustomError(lendingPool, "NotUnderLiquidation");

      // Attempt to close liquidation by non-owner (user2)
      await expect(
        lendingPool.connect(user2).finalizeLiquidation(user1.address)
      ).to.be.revertedWithCustomError(lendingPool, "Unauthorized");
    });

    it("should prevent Stability Pool from closing liquidation within grace period", async function () {
      // Decrease house price and initiate liquidation
      // FIXME: we are using price oracle and therefore the price should be changed from the oracle.
      await raacHousePrices.setHousePrice(1, ethers.parseEther("90"));
      await lendingPool.connect(user2).initiateLiquidation(user1.address);

      // Set Stability Pool address (using owner for this test)
      await lendingPool.connect(owner).setStabilityPool(owner.address);

      // Attempt to close liquidation by Stability Pool within grace period
      await expect(
        lendingPool.connect(owner).finalizeLiquidation(user1.address)
      ).to.be.revertedWithCustomError(lendingPool, "GracePeriodNotExpired");
    });
  });

  describe("Withdrawal Specific Pause", function () {
    beforeEach(async function () {
      const depositAmount = ethers.parseEther("100");
      await crvusd.connect(user1).approve(lendingPool.target, depositAmount);
      await lendingPool.connect(user1).deposit(depositAmount);
    });

    it("should allow owner to pause and unpause withdrawals", async function () {
      await lendingPool.connect(owner).setParameter(4, 1); // WithdrawalStatus = 4, true = 1
      expect(await lendingPool.withdrawalsPaused()).to.be.true;

      await lendingPool.connect(owner).setParameter(4, 0); // WithdrawalStatus = 4, false = 0
      expect(await lendingPool.withdrawalsPaused()).to.be.false;
    });

    it("should prevent withdrawals when withdrawals are paused but allow other operations", async function () {
      await lendingPool.connect(owner).setParameter(4, 1); // WithdrawalStatus = 4, true = 1

      // Attempt withdrawal should fail
      await expect(
        lendingPool.connect(user1).withdraw(ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(lendingPool, "WithdrawalsArePaused");

      // Other operations should still work
      const depositAmount = ethers.parseEther("10");
      await crvusd.connect(user2).approve(lendingPool.target, depositAmount);
      await expect(lendingPool.connect(user2).deposit(depositAmount)).to.not.be
        .reverted;

      // NFT operations should still work
      const tokenId = 1;
      await raacNFT.connect(user1).approve(lendingPool.target, tokenId);
      await expect(lendingPool.connect(user1).depositNFT(tokenId)).to.not.be
        .reverted;
    });

    it("should prevent non-owner from pausing withdrawals", async function () {
      await expect(
        lendingPool.connect(user1).setParameter(4, 1)
      ).to.be.revertedWithCustomError(
        lendingPool,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should allow withdrawals after unpausing", async function () {
      await lendingPool.connect(owner).setParameter(4, 1); // WithdrawalStatus = 4, true = 1
      await lendingPool.connect(owner).setParameter(4, 0); // WithdrawalStatus = 4, false = 0

      const withdrawAmount = ethers.parseEther("10");
      await expect(lendingPool.connect(user1).withdraw(withdrawAmount)).to.not
        .be.reverted;
    });
  });

  describe("Parameter Setting", function () {
    it("should allow owner to set liquidation threshold", async function () {
      const newValue = 7500; // 75%
      await lendingPool.connect(owner).setParameter(0, newValue); // LiquidationThreshold = 0
      expect(await lendingPool.liquidationThreshold()).to.equal(newValue);
    });

    it("should allow owner to set health factor liquidation threshold", async function () {
      const newValue = ethers.parseEther("1.1");
      await lendingPool.connect(owner).setParameter(1, newValue); // HealthFactorLiquidationThreshold = 1
      expect(await lendingPool.healthFactorLiquidationThreshold()).to.equal(
        newValue
      );
    });

    it("should allow owner to set liquidation grace period", async function () {
      const newValue = 2 * 24 * 60 * 60; // 2 days
      await lendingPool.connect(owner).setParameter(2, newValue); // LiquidationGracePeriod = 2
      expect(await lendingPool.liquidationGracePeriod()).to.equal(newValue);
    });

    it("should allow owner to set liquidity buffer ratio", async function () {
      const newValue = 3000; // 30%
      await lendingPool.connect(owner).setParameter(3, newValue); // LiquidityBufferRatio = 3
      expect(await lendingPool.liquidityBufferRatio()).to.equal(newValue);
    });

    it("should allow owner to set can payback debt", async function () {
      await lendingPool.connect(owner).setParameter(5, 0); // CanPaybackDebt = 5, false = 0
      expect(await lendingPool.canPaybackDebt()).to.be.false;

      await lendingPool.connect(owner).setParameter(5, 1); // CanPaybackDebt = 5, true = 1
      expect(await lendingPool.canPaybackDebt()).to.be.true;
    });

    it("should revert when setting invalid values", async function () {
      // Invalid liquidation threshold (> 100%)
      await expect(
        lendingPool.connect(owner).setParameter(0, 10100)
      ).to.be.revertedWith("Invalid liquidation threshold");

      // Invalid grace period (> 7 days)
      await expect(
        lendingPool.connect(owner).setParameter(2, 8 * 24 * 60 * 60)
      ).to.be.revertedWith("Invalid grace period");

      // Invalid buffer ratio (> 100%)
      await expect(
        lendingPool.connect(owner).setParameter(3, 10100)
      ).to.be.revertedWith("Ratio cannot exceed 100%");

      // Invalid boolean value
      await expect(
        lendingPool.connect(owner).setParameter(5, 2)
      ).to.be.revertedWith("Invalid boolean value");
    });
  });
});
