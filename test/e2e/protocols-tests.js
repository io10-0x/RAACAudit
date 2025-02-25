import { assert, expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { deployContracts } from "./utils/deployContracts.js";

describe("Protocol E2E Tests", function () {
  // Set higher timeout for deployments
  this.timeout(300000); // 5 minutes

  let contracts;
  let owner, user1, user2, user3, treasury, repairFund;
  const INITIAL_MINT_AMOUNT = ethers.parseEther("1000");
  const HOUSE_TOKEN_ID = "1021000";
  const HOUSE_PRICE = ethers.parseEther("100");
  const ONE_YEAR = 365 * 24 * 3600;
  const FOUR_YEARS = 4 * ONE_YEAR;
  const BASIS_POINTS = 10000;

  before(async function () {
    [owner, user1, user2, user3, treasury, repairFund] =
      await ethers.getSigners();
    contracts = await deployContracts(owner, user1, user2, user3);
    const displayContracts = Object.fromEntries(
      Object.entries(contracts).map(([key, value]) => [key, value.target])
    );
    console.log(displayContracts);

    // Set house price for testing
    await contracts.housePrices.setHousePrice(HOUSE_TOKEN_ID, HOUSE_PRICE);

    // Mint initial tokens to users
    for (const user of [user1, user2, user3]) {
      await contracts.crvUSD.mint(user.address, INITIAL_MINT_AMOUNT);
      await contracts.altReserveAsset
        .connect(owner)
        .mintTo(user.address, INITIAL_MINT_AMOUNT);
    }
  });

  describe("RAAC Token", function () {
    const TRANSFER_AMOUNT = ethers.parseEther("100");

    it("should handle RAAC token transfers with tax and fee collection", async function () {
      const user2InitialBalance = await contracts.raacToken.balanceOf(
        user2.address
      );
      expect(user2InitialBalance).to.be.eq(INITIAL_MINT_AMOUNT);

      const initialFeeCollectorBalance = await contracts.raacToken.balanceOf(
        contracts.feeCollector.target
      );
      const initialUser1Balance = await contracts.raacToken.balanceOf(
        user1.address
      );
      await contracts.raacToken
        .connect(user2)
        .transfer(user1.address, TRANSFER_AMOUNT);

      const finalUser2Balance = await contracts.raacToken.balanceOf(
        user2.address
      );
      expect(finalUser2Balance).to.be.eq(INITIAL_MINT_AMOUNT - TRANSFER_AMOUNT);

      const finalUser1Balance = await contracts.raacToken.balanceOf(
        user1.address
      );
      expect(finalUser1Balance).to.be.gt(initialUser1Balance);
      expect(finalUser1Balance).to.be.lt(initialUser1Balance + TRANSFER_AMOUNT); // less due to tax

      const finalFeeCollectorBalance = await contracts.raacToken.balanceOf(
        contracts.feeCollector.target
      );

      expect(finalUser2Balance).to.be.lt(user2InitialBalance);
      expect(finalUser2Balance).to.be.eq(user2InitialBalance - TRANSFER_AMOUNT);
      expect(finalFeeCollectorBalance).to.be.gt(initialFeeCollectorBalance); // Collected fees
    });

    it("should handle whitelist operations and repair fund collection", async function () {
      // Done in deployContracts
      // await contracts.raacToken.connect(owner).manageWhitelist(owner.address, true);
      const initialRepairFundBalance = await contracts.raacToken.balanceOf(
        contracts.repairFund.target
      );
      const initialFeeCollectorBalance = await contracts.raacToken.balanceOf(
        contracts.feeCollector.target
      );
      await contracts.raacToken
        .connect(user3)
        .transfer(owner.address, TRANSFER_AMOUNT * 2n);

      await contracts.raacToken
        .connect(owner)
        .transfer(user2.address, TRANSFER_AMOUNT);
      const finalRepairFundBalance = await contracts.raacToken.balanceOf(
        contracts.repairFund.target
      );
      const finalFeeCollectorBalance = await contracts.raacToken.balanceOf(
        contracts.feeCollector.target
      );
      expect(finalRepairFundBalance).to.be.eq(initialRepairFundBalance);
      expect(finalFeeCollectorBalance).to.be.eq(initialFeeCollectorBalance);
    });
  });

  describe("veRAACToken Locks", function () {
    const STAKE_AMOUNT = ethers.parseEther("500");

    it("should handle lock creation with boost calculations", async function () {
      // User2: 1 year lock
      await contracts.raacToken
        .connect(user2)
        .approve(contracts.veRAACToken.target, STAKE_AMOUNT);
      const unlockDuration1 = ONE_YEAR;
      await contracts.veRAACToken
        .connect(user2)
        .lock(STAKE_AMOUNT, unlockDuration1);

      // User3: 4 year lock
      await contracts.raacToken
        .connect(user3)
        .approve(contracts.veRAACToken.target, STAKE_AMOUNT);
      const unlockDuration2 = FOUR_YEARS;
      console.log(unlockDuration2);
      await contracts.veRAACToken
        .connect(user3)
        .lock(STAKE_AMOUNT, unlockDuration2);

      // Verify voting power ratio and boost
      const user2Power = await contracts.veRAACToken.balanceOf(user2.address);
      const user3Power = await contracts.veRAACToken.balanceOf(user3.address);
      const powerRatio = Number(user3Power) / Number(user2Power);
      expect(powerRatio).to.be.closeTo(4, 0.5);

      // Verify boost calculation
      const user2Boost = await contracts.veRAACToken.getCurrentBoost(
        user2.address
      );
      expect(user2Boost).to.be.deep.eq([13000n, 650000000000000000000n]);
      const user3Boost = await contracts.veRAACToken.getCurrentBoost(
        user3.address
      );
      expect(user3Boost).to.be.deep.eq([22000n, 1100000000000000000000n]);
      expect(user3Boost[1]).to.be.gt(user2Boost[1]);
      expect(user3Boost[0]).to.be.gt(user2Boost[0]);

      const user2LockPosition = await contracts.veRAACToken.getLockPosition(
        user2.address
      );
      expect(user2LockPosition.amount).to.be.eq(STAKE_AMOUNT);
      expect(user2LockPosition.power).to.be.eq(user2Power);
      const user3LockPosition = await contracts.veRAACToken.getLockPosition(
        user3.address
      );
      expect(user3LockPosition.amount).to.be.eq(STAKE_AMOUNT);
      expect(user3LockPosition.power).to.be.eq(user3Power);
    });

    it("should handle lock extension", async function () {
      const initialPower = await contracts.veRAACToken.balanceOf(user2.address);

      // Move forward 6 months and check decay =?
      // await time.increase(180 * 24 * 3600);
      const midPower = await contracts.veRAACToken.balanceOf(user2.address);
      // expect(midPower).to.be.lt(initialPower);

      // Extend lock and verify power increase
      const newUnlockDuration = 3 * ONE_YEAR;
      await contracts.veRAACToken.connect(user2).extend(newUnlockDuration);
      const finalPower = await contracts.veRAACToken.balanceOf(user2.address);
      expect(finalPower).to.be.gt(midPower);
    });
  });

  describe("LendingPool", function () {
    const DEPOSIT_AMOUNT = ethers.parseEther("500");
    const BORROW_AMOUNT = ethers.parseEther("10");

    it("should handle interest rate scenarios", async function () {
      // Initial state
      await contracts.crvUSD
        .connect(user1)
        .approve(contracts.lendingPool.target, DEPOSIT_AMOUNT);
      await contracts.lendingPool.connect(user1).deposit(DEPOSIT_AMOUNT);

      // Create NFT collateral and borrow
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, ethers.parseEther("1"));
      // Allow to spend crvUSD
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(HOUSE_TOKEN_ID, HOUSE_PRICE);

      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, HOUSE_TOKEN_ID);
      await contracts.lendingPool.connect(user2).depositNFT(HOUSE_TOKEN_ID);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // Record initial rates
      const initialRate = await contracts.lendingPool.rateData();
      // Create high utilization
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT * 4n);

      // Verify rate increases
      const finalRate = await contracts.lendingPool.rateData();
      // Liquidity rate
      expect(finalRate[0]).to.be.gt(initialRate[0]);
      // usage rate
      expect(finalRate[1]).to.be.gt(initialRate[1]);
    });

    it("should handle liquidation with grace period scenarios", async function () {
      // Setup new position
      const newTokenId = HOUSE_TOKEN_ID + 1;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user3).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user3)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user3).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user3).borrow(BORROW_AMOUNT);

      // Trigger liquidation
      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 10n) / 100n
      );
      await contracts.lendingPool
        .connect(user1)
        .initiateLiquidation(user3.address);

      // Attempt repayment within grace period
      const debt = await contracts.debtToken.balanceOf(user3.address);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.lendingPool.target, debt * 2n);
      await contracts.lendingPool.connect(user3).repay(debt * 2n);
      await contracts.lendingPool.connect(user3).closeLiquidation();

      expect(await contracts.lendingPool.isUnderLiquidation(user3.address)).to
        .be.false;
    });
  });

  describe("StabilityPool", function () {
    const STABILITY_DEPOSIT = ethers.parseEther("100");
    const BORROW_AMOUNT = ethers.parseEther("50");

    beforeEach(async function () {
      await contracts.crvUSD
        .connect(user1)
        .approve(contracts.lendingPool.target, STABILITY_DEPOSIT);
      await contracts.lendingPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.rToken
        .connect(user1)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
    });

    /*beforeEach(async function () {
      await contracts.altReserveAsset
        .connect(user1)
        .approve(contracts.lendingPool.target, STABILITY_DEPOSIT);
      await contracts.lendingPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.rToken
        .connect(user1)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
    }); */

    it("should handle liquidation absorption", async function () {
      // Setup stability pool deposit
      await contracts.stabilityPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .transfer(contracts.stabilityPool.target, STABILITY_DEPOSIT); //c this is where the stability pool gets the crvUSD to cover the debt

      // Create position to be liquidated
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // Trigger and complete liquidation
      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 10n) / 100n
      );
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);
      await time.increase(73 * 60 * 60);
      // Will call the lendingPool.finalizeLiquidation(user2.address)
      // We need stability pool to have crvUSD to cover the debt
      const initialBalance = await contracts.crvUSD.balanceOf(
        contracts.stabilityPool.target
      );
      await contracts.lendingPool.connect(owner).updateState();
      const tx = await contracts.stabilityPool
        .connect(owner)
        .liquidateBorrower(user2.address);

      // Verify stability pool state
      const finalDeposit = await contracts.stabilityPool.getUserDeposit(
        user1.address
      );
      expect(finalDeposit).to.be.eq(STABILITY_DEPOSIT);

      const finalDebt = await contracts.debtToken.balanceOf(user2.address);
      expect(finalDebt).to.be.closeTo(0, 1 * 10 ** 14);
      const finalBalance = await contracts.crvUSD.balanceOf(
        contracts.stabilityPool.target
      );
      expect(finalBalance).to.be.lt(initialBalance - BORROW_AMOUNT);
      // Check RAAC rewards
      const raacRewards = await contracts.stabilityPool.calculateRaacRewards(
        user1.address
      );
      expect(raacRewards).to.be.gt(0);
    });

    it("user is wrongfully liquidated when health factor is above threshold", async function () {
      //c for testing purposes

      await contracts.stabilityPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .transfer(contracts.stabilityPool.target, STABILITY_DEPOSIT); //c this is where the stability pool gets the crvUSD to cover the debt

      // Create position to be liquidated
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool
        .connect(user2)
        .borrow(ethers.parseEther("90"));

      //c at this point, the user's health factor is unhealthy so they can be liquidated
      const user2healthfactor =
        await contracts.lendingPool.calculateHealthFactor(user2.address);
      console.log(`user2healthfactor: ${user2healthfactor}`);

      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);
      await time.increase(24 * 60 * 60);

      //c between the grace period, the house price increases to a value that would make the user's health factor healthy again
      await contracts.housePrices.setHousePrice(
        newTokenId,
        ethers.parseEther("150")
      );

      //c user comes in to perform a routine health factor check after 24 hours and since they are healthy and dont know that liquidation has been initialized on their address, they feel they are safe so they carry on with their activities as usual
      const user2healthfactor1 =
        await contracts.lendingPool.calculateHealthFactor(user2.address);
      console.log(`user2healthfactor1: ${user2healthfactor1}`);

      const healthFactorLiquidationThreshold =
        await contracts.lendingPool.BASE_HEALTH_FACTOR_LIQUIDATION_THRESHOLD();

      assert(user2healthfactor1 > user2healthfactor);
      assert(user2healthfactor1 > healthFactorLiquidationThreshold);

      //c another 2 days pass which means the grace period is now over
      await time.increase(49 * 60 * 60);

      //c since initiateliquidation has been called, the stability pool will liquidate user2 successfully which shouldnt happen because the user's health factor was healthy before the grace period ended
      await contracts.lendingPool.connect(owner).updateState();
      const tx = await contracts.stabilityPool
        .connect(owner)
        .liquidateBorrower(user2.address);
    });

    it("no incentive to call initiate liquidity", async function () {
      //c for testing purposes

      // User deposits NFT and borrows funds
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool
        .connect(user2)
        .borrow(ethers.parseEther("80"));

      const initialblocktimestamp = (await ethers.provider.getBlock("latest"))
        .timestamp;
      console.log(`initialblocktimestamp: ${initialblocktimestamp}`);

      // The user’s health factor drops below the threshold
      await contracts.housePrices.setHousePrice(
        newTokenId,
        ethers.parseEther("50")
      );

      // No one calls `initiateLiquidation` for a long time, allowing the user to remain liquidatable but not in liquidation

      await time.increase(7 * 24 * 60 * 60); // Simulating 7 days
      await ethers.provider.send("evm_mine", []);

      // Now someone finally calls `initiateLiquidation`
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);

      const updatedblocktimestamp = (await ethers.provider.getBlock("latest"))
        .timestamp;
      console.log(`updatedblocktimestamp: ${updatedblocktimestamp}`);

      // Grace period starts now, giving the user even more time to recover when in reality, the user has had way over the grace period to recover
      const graceperiod =
        await contracts.lendingPool.BASE_LIQUIDATION_GRACE_PERIOD();
      assert(updatedblocktimestamp - initialblocktimestamp > graceperiod);
    });

    it("userdebtisdoublecounted", async function () {
      //c for testing purposes
      // Setup stability pool deposit

      // Create position to be liquidated
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);

      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // Trigger and complete liquidation
      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 10n) / 100n
      );
      //c need to increase time to allow usage index to update
      await time.increase(73 * 60 * 60);
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);
      await time.increase(73 * 60 * 60);
      // Will call the lendingPool.finalizeLiquidation(user2.address)

      //c get the user debt before liquidation. need to update state to update the usage index
      contracts.lendingPool.updateState();
      const userdebt = await contracts.lendingPool.getUserDebt(user2.address);
      console.log(`userdebt: ${userdebt}`);

      const reservedata1 = await contracts.lendingPool.getAllUserData(
        user2.address
      );
      console.log(
        `reservedata1.scaledDebtBalance: ${reservedata1.scaledDebtBalance}`
      );
      //c IMPORTANT: to get this to display the correct userscaleddebtbalance, you need to go into lendingpool::getalluserdata and change the scaledDebtBalance return value to user.scaledDebtBalance instead of getUserDebt(userAddress)

      console.log(`usageindex: ${reservedata1.usageIndex}`);

      const expecteddebt = await contracts.reserveLibrary.raymul(
        reservedata1.scaledDebtBalance,
        reservedata1.usageIndex
      );
      console.log(`expecteddebt: ${expecteddebt}`);

      //c send sufficient amount of crvUSD to the stability pool to cover the expected debt
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .transfer(contracts.stabilityPool.target, expecteddebt);

      /*c IMPORTANT: for this test to work, first go to reservelibrarymock.sol and include the following function:
      function raymul(
        uint256 val1,
        uint256 val2
    ) external pure returns (uint256) {
        return val1.rayMul(val2);
    }
       
       
       go into deploycontracts.js and add the following line:
       //c deploy reservelibrarymock
  const reserveLibrary = await deployContract("ReserveLibraryMock", []);
  and add  reserveLibrary to the return statement of deployContracts.js
       */

      //c prove that the userdebt is greater than their borrow amount which proves that the usage index has already been applied to it

      assert(userdebt > BORROW_AMOUNT);

      //c get normalized debt
      const normalizeddebt = await contracts.lendingPool.getNormalizedDebt();
      console.log(`normalizeddebt: ${normalizeddebt}`);

      await contracts.lendingPool.connect(owner).updateState();

      await expect(
        contracts.stabilityPool.connect(owner).liquidateBorrower(user2.address)
      ).to.be.revertedWithCustomError(
        contracts.stabilityPool,
        "InsufficientBalance"
      );
    });

    it("usageindexnotupdated", async function () {
      //c for testing purposes. this is no longer an issue because the state of the reserve is updated in lendingpool::finalizeliquidation which i didnt see before but I will keep this test here for reference
      // Setup stability pool deposit
      await contracts.stabilityPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
      await contracts.crvUSD
        .connect(user3)
        .transfer(contracts.stabilityPool.target, STABILITY_DEPOSIT);

      // Create position to be liquidated
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);

      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // Trigger and complete liquidation
      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 10n) / 100n
      );
      //c need to increase time to allow usage index to update
      await time.increase(73 * 60 * 60);
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);

      //c wait for some time after intializing liquidation to allow usage index to update
      await time.increase(73 * 60 * 60);
      // Will call the lendingPool.finalizeLiquidation(user2.address)

      //c get the user debt before liquidation. need to update state to update the usage index

      const userdebt = await contracts.lendingPool.getUserDebt(user2.address);
      console.log(`userdebt: ${userdebt}`);

      const reservedata1 = await contracts.lendingPool.getAllUserData(
        user2.address
      );

      console.log(`usageindex: ${reservedata1.usageIndex}`);

      await contracts.lendingPool.connect(owner).updateState();
      const tx = await contracts.stabilityPool
        .connect(owner)
        .liquidateBorrower(user2.address);

      //c get scaleddebtbalance from event logs
      const txreceipt = await tx.wait();
      const eventLogs = txreceipt.logs;
      let actualuserdebt;
      for (let log of eventLogs) {
        if (log.fragment && log.fragment.name == "BorrowerLiquidated") {
          actualuserdebt = log.args[1];
          break;
        }
      }

      console.log(`actualdebt :${actualuserdebt}`);

      //c no time has passed since borrower was liquidated but as we will see, the usage index will have changed which shows that the correct usage index that should have been applied to the debt was not applied
      contracts.lendingPool.updateState();

      const reservedata2 = await contracts.lendingPool.getAllUserData(
        user2.address
      );

      console.log(`usageindex: ${reservedata2.usageIndex}`);

      //c get expected user debt with updated usage index
      const expecteddebt = await contracts.reserveLibrary.raymul(
        reservedata1.scaledDebtBalance,
        reservedata2.usageIndex
      );
      console.log(`expecteddebt: ${expecteddebt}`);

      assert(reservedata1.usageIndex != reservedata2.usageIndex);
      assert(actualuserdebt != expecteddebt);
    });

    it("liquidation not possible if reserveAsset is not crvUSD", async function () {
      //c for testing purposes
      // Setup stability pool deposit
      //await contracts.stabilityPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.altReserveAsset
        .connect(owner)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
      await contracts.altReserveAsset
        .connect(owner)
        .transfer(contracts.stabilityPool.target, STABILITY_DEPOSIT); //c this is where the stability pool gets the reserveAsset to cover the debt

      /*c to get access to the altReserveAsset, go to deploycontracts.js, deploy the altReserveAsset with the following line ABOVE the rtoken and lending pool contract deployments:
      
      //c get new mockerc20 contract to use as reserve asset
        const altReserveAsset = await deployContract("RAACMockERC20", [
          owner.address,
        ]);
   
       and in the rToken deployment, add the altReserveAsset.target to the arguments and remove crvUSD.target. Do the same for the lendingPool deployment and modify the above beforeEach hook as follows:

      /*beforeEach(async function () {
      await contracts.altReserveAsset
        .connect(user1)
        .approve(contracts.lendingPool.target, STABILITY_DEPOSIT);
      await contracts.lendingPool.connect(user1).deposit(STABILITY_DEPOSIT);
      await contracts.rToken
        .connect(user1)
        .approve(contracts.stabilityPool.target, STABILITY_DEPOSIT);
    }); */

      // Create position to be liquidated
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // Trigger and complete liquidation
      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 10n) / 100n
      );
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);
      await time.increase(73 * 60 * 60);
      // Will call the lendingPool.finalizeLiquidation(user2.address)
      // We need stability pool to have correct reserveasset amount to cover the debt
      const initialBalance = await contracts.altReserveAsset.balanceOf(
        contracts.stabilityPool.target
      );
      //c this will revert when it shouldnt because the stability pool should be able to liquidate the borrower with the reserveAsset it has but it doesnt because the function checks the crvUSD balance of the stability pool when it should check the balance of the reserve asset.
      await contracts.lendingPool.connect(owner).updateState();
      await expect(
        contracts.stabilityPool.connect(owner).liquidateBorrower(user2.address)
      ).to.be.revertedWithCustomError(
        contracts.stabilityPool,
        "InsufficientBalance"
      );
    });

    it("test minter utilization rate never less than utilization target after first deposit", async function () {
      //c for testing purposes
      const preupdateemissionrate = await contracts.minter.getEmissionRate();
      console.log(`preupdateemissionrate: ${preupdateemissionrate}`);
      console.log(`benchmark: ${await contracts.minter.benchmarkRate()}`);

      const utilratepredeposit = await contracts.minter.getUtilizationRate();
      console.log(`utilratepredeposit: ${utilratepredeposit}`);
      //c start from a position where there is no debt in the protocol but there are rtoken deposits in the stability pool. In this position, the utilization rate should be 0 but it wont be due to wrong calculation in the minter contract

      //c deposit function calls raacminter::tick which updatesemissionrate when utilization rate is 0 so the emission rate will decrease on the first mint as expected
      await contracts.stabilityPool.connect(user1).deposit(STABILITY_DEPOSIT);

      //c to run this test, temporarily, change the getUtilizationRate() function in the minter contract to public. This will show the incorrect utilization rate. since there is no debt accrued in the lending pool, the utilization rate should be 0 but it isnt because the minter contract calculates the utilization rate incorrectly
      const mintutilrate = await contracts.minter.getUtilizationRate();
      console.log(`mintutilrate: ${mintutilrate}`);
      assert(mintutilrate > 0);
      const emissionrateafterdeposit = await contracts.minter.getEmissionRate();
      console.log(`emissionrateafterdeposit: ${emissionrateafterdeposit}`);

      //allow some time to pass with no more deposits or borrows. then updateemissionsrate and see that the rate has increased to match the benchmark rate when it should decrease
      await time.increase(73 * 60 * 60);
      await contracts.minter.updateEmissionRate();
      const postupdateemissionrate = await contracts.minter.getEmissionRate();
      console.log(`postupdateemissionrate: ${postupdateemissionrate}`);
      assert(postupdateemissionrate > emissionrateafterdeposit);
    });

    it("totalsupply incorrect value", async function () {
      //c for testing purposes

      //c borrow tokens to allow for usage index to update
      const newTokenId = HOUSE_TOKEN_ID + 2;
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);

      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      //c allow time to pass to update usage index
      await time.increase(73 * 60 * 60);

      const scaledbal = await contracts.debtToken.scaledBalanceOf(
        user2.address
      );
      console.log(`totalsupply: ${scaledbal}`);

      const reservedata = await contracts.lendingPool.getAllUserData(
        user2.address
      );
      const usageindex = reservedata.usageIndex;

      const expectedtotalsupply = await contracts.reserveLibrary.raymul(
        scaledbal,
        usageindex
      );
      console.log("expectedtotalsupply: ", expectedtotalsupply);

      const actualtotalsupply = await contracts.debtToken.totalSupply();
      console.log("actualtotalsupply: ", actualtotalsupply);

      assert(actualtotalsupply < expectedtotalsupply);
    });
  });

  describe("Emergency Controls and Governance", function () {
    it("should handle emergency pauses", async function () {
      // Test lending pool pause
      await contracts.lendingPool.connect(owner).setParameter(4, 1); // Pause withdrawals
      await expect(
        contracts.lendingPool.connect(user1).withdraw(ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(
        contracts.lendingPool,
        "WithdrawalsArePaused"
      );

      // Test stability pool pause
      await contracts.stabilityPool.pause();
      await expect(
        contracts.stabilityPool.connect(user1).deposit(ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(contracts.stabilityPool, "EnforcedPause");

      // Cleanup
      await contracts.lendingPool.connect(owner).setParameter(4, 0);
      await contracts.stabilityPool.unpause();
    });

    it("should handle parameter updates", async function () {
      // Update lending pool parameters
      await contracts.lendingPool.connect(owner).setParameter(0, 7500); // Liquidation threshold
      expect(await contracts.lendingPool.liquidationThreshold()).to.equal(7500);

      const newHealthFactor = ethers.parseEther("1.1");
      await contracts.lendingPool
        .connect(owner)
        .setParameter(1, newHealthFactor);
      expect(
        await contracts.lendingPool.healthFactorLiquidationThreshold()
      ).to.equal(newHealthFactor);

      // Update RAAC parameters (only owner of RAAC can do this, which is the minter)
      // const newTaxRate = 150; // 1.5%
      // await contracts.raacToken.setSwapTaxRate(newTaxRate);
      // expect(await contracts.raacToken.swapTaxRate()).to.equal(newTaxRate);
    });
  });

  describe("Full process", function () {
    const DEPOSIT_AMOUNT = ethers.parseEther("125");
    const BORROW_AMOUNT = ethers.parseEther("100");
    const INITIAL_DEPOSIT = ethers.parseEther("500");

    it("should perform a full lifecycle", async function () {
      // Setup initial states
      await contracts.crvUSD.mint(user3.address, ethers.parseEther("3000"));
      await contracts.crvUSD.mint(user1.address, ethers.parseEther("2000"));
      const depositAmount = ethers.parseEther("125");
      const borrowAmount = ethers.parseEther("100");

      // User3 to provide liquidity and lock
      // const initialUser3Balance = await contracts.crvUSD.balanceOf(user3.address);
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.lendingPool.target, DEPOSIT_AMOUNT);
      await contracts.lendingPool.connect(user3).deposit(DEPOSIT_AMOUNT);
      const user3RTokenBalance = await contracts.rToken.balanceOf(
        user3.address
      );
      expect(user3RTokenBalance).to.be.eq(DEPOSIT_AMOUNT);

      await contracts.raacToken
        .connect(user3)
        .approve(contracts.veRAACToken.target, DEPOSIT_AMOUNT);
      await contracts.veRAACToken.connect(user3).lock(DEPOSIT_AMOUNT, ONE_YEAR);

      // User2 will borrow against NFT
      const newTokenId = "1021111";
      await contracts.housePrices.setHousePrice(newTokenId, HOUSE_PRICE);
      await contracts.crvUSD
        .connect(user2)
        .approve(contracts.nft.target, HOUSE_PRICE);
      await contracts.nft.connect(user2).mint(newTokenId, HOUSE_PRICE);
      await contracts.nft
        .connect(user2)
        .approve(contracts.lendingPool.target, newTokenId);
      await contracts.lendingPool.connect(user2).depositNFT(newTokenId);
      await contracts.lendingPool.connect(user2).borrow(BORROW_AMOUNT);

      // User1 to provide stability pool funding (rtoken received from lending pool)
      await contracts.crvUSD
        .connect(user1)
        .approve(contracts.lendingPool.target, DEPOSIT_AMOUNT);
      await contracts.lendingPool.connect(user1).deposit(DEPOSIT_AMOUNT);
      // check rtoken balance of user1
      const user1RTokenBalance = await contracts.rToken.balanceOf(
        user1.address
      );
      expect(user1RTokenBalance).to.be.gt(DEPOSIT_AMOUNT + INITIAL_DEPOSIT);

      await contracts.rToken
        .connect(user1)
        .approve(contracts.stabilityPool.target, INITIAL_DEPOSIT);
      await contracts.stabilityPool.connect(user1).deposit(INITIAL_DEPOSIT);

      // Move time and accumulate rewards
      await time.increase(30 * 24 * 60 * 60);
      await contracts.minter.tick();

      // Trigger liquidation scenario (pool will need balance)
      await contracts.crvUSD
        .connect(user3)
        .approve(contracts.stabilityPool.target, BORROW_AMOUNT * 2n);
      await contracts.crvUSD
        .connect(user3)
        .transfer(contracts.stabilityPool.target, BORROW_AMOUNT * 2n);

      await contracts.housePrices.setHousePrice(
        newTokenId,
        (HOUSE_PRICE * 50n) / 100n
      );
      await contracts.lendingPool
        .connect(user3)
        .initiateLiquidation(user2.address);
      await time.increase(73 * 60 * 60);
      await contracts.lendingPool.connect(owner).updateState();
      await contracts.stabilityPool
        .connect(owner)
        .liquidateBorrower(user2.address);

      // User 2 and user 3 has RAAC token, lets transfer some to user 1
      await contracts.raacToken
        .connect(user2)
        .transfer(user1.address, ethers.parseEther("25"));
      await contracts.raacToken
        .connect(user3)
        .transfer(user1.address, ethers.parseEther("25"));

      // Get final balances
      const finalTreasuryBalance = await contracts.raacToken.balanceOf(
        contracts.treasury.target
      );
      const finalRepairFundBalance = await contracts.raacToken.balanceOf(
        contracts.repairFund.target
      );
      console.log(finalTreasuryBalance, finalRepairFundBalance);

      // Verify final states and rewards
      expect(await contracts.debtToken.balanceOf(user2.address)).to.closeTo(
        0,
        1 * 10 ** 14
      );
      expect(
        await contracts.raacToken.balanceOf(contracts.feeCollector.target)
      ).to.be.gt(0);

      const stabilityPoolRewards =
        await contracts.stabilityPool.calculateRaacRewards(user1.address);
      expect(stabilityPoolRewards).to.be.gt(0);

      // Close remaining positions
      const stabilityDeposit = await contracts.stabilityPool.getUserDeposit(
        user1.address
      );
      await contracts.stabilityPool.connect(user1).withdraw(stabilityDeposit);

      // Verify all positions closed
      expect(
        await contracts.stabilityPool.getUserDeposit(user1.address)
      ).to.equal(0);
    });
  });
});
