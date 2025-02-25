import { time } from "@nomicfoundation/hardhat-network-helpers";
import { assert, expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;

describe("GaugeController", () => {
  let gaugeController;
  let rwaGauge;
  let raacGauge;
  let veRAACToken;
  let rewardToken;
  let owner;
  let gaugeAdmin;
  let emergencyAdmin;
  let feeAdmin;
  let raacToken;
  let user1;
  let user2;
  let user3;
  let user4;
  let users;

  const MONTH = 30 * 24 * 3600;
  const WEEK = 7 * 24 * 3600;
  const WEIGHT_PRECISION = 10000;
  const { MaxUint256 } = ethers;
  const duration = 365 * 24 * 3600; // 1 year

  beforeEach(async () => {
    [
      owner,
      gaugeAdmin,
      emergencyAdmin,
      feeAdmin,
      user1,
      user2,
      user3,
      user4,
      ...users
    ] = await ethers.getSigners(); //c added ...users to get all users and added users 3 and 4 to the list of users for testing purposes

    // Deploy Mock tokens
    const MockToken = await ethers.getContractFactory("MockToken");
    /*veRAACToken = await MockToken.deploy("veRAAC Token", "veRAAC", 18);
    await veRAACToken.waitForDeployment();
    const veRAACAddress = await veRAACToken.getAddress(); */

    //c this should use the actual veRAACToken address and not a mock token as veRAAC has different mechanics to this mocktoken because the rate of decay is not considered at all in this mock token which allows for limiting POC's that produce false positives. the above code block was commented out for testing purposes

    const MockRAACToken = await ethers.getContractFactory("ERC20Mock");
    raacToken = await MockRAACToken.deploy("RAAC Token", "RAAC");
    await raacToken.waitForDeployment();

    const VeRAACToken = await ethers.getContractFactory("veRAACToken");
    veRAACToken = await VeRAACToken.deploy(await raacToken.getAddress());
    await veRAACToken.waitForDeployment();
    const veRAACAddress = await veRAACToken.getAddress();

    rewardToken = await MockToken.deploy("Reward Token", "REWARD", 18);
    await rewardToken.waitForDeployment();
    const rewardTokenAddress = await rewardToken.getAddress();

    // Deploy GaugeController with correct parameters
    const GaugeController = await ethers.getContractFactory("GaugeController");
    gaugeController = await GaugeController.deploy(veRAACAddress);
    await gaugeController.waitForDeployment();
    const gaugeControllerAddress = await gaugeController.getAddress();

    // Deploy RWAGauge with correct parameters
    const RWAGauge = await ethers.getContractFactory("RWAGauge");
    rwaGauge = await RWAGauge.deploy(
      await rewardToken.getAddress(),
      await veRAACToken.getAddress(),
      await gaugeController.getAddress()
    );
    await rwaGauge.waitForDeployment();

    // Deploy RAACGauge with correct parameters
    const RAACGauge = await ethers.getContractFactory("RAACGauge");
    raacGauge = await RAACGauge.deploy(
      await rewardToken.getAddress(),
      await veRAACToken.getAddress(),
      await gaugeController.getAddress()
    );
    await raacGauge.waitForDeployment();

    // Setup roles
    const GAUGE_ADMIN_ROLE = await gaugeController.GAUGE_ADMIN();
    const EMERGENCY_ADMIN_ROLE = await gaugeController.EMERGENCY_ADMIN();
    const FEE_ADMIN_ROLE = await gaugeController.FEE_ADMIN();

    await gaugeController.grantRole(GAUGE_ADMIN_ROLE, gaugeAdmin.address);
    await gaugeController.grantRole(
      EMERGENCY_ADMIN_ROLE,
      emergencyAdmin.address
    );
    await gaugeController.grantRole(FEE_ADMIN_ROLE, feeAdmin.address);

    // Add gauges
    await gaugeController.connect(gaugeAdmin).addGauge(
      await rwaGauge.getAddress(),
      0, // RWA type
      0 // Initial weight
    );
    await gaugeController.connect(gaugeAdmin).addGauge(
      await raacGauge.getAddress(),
      1, // RAAC type
      0 // Initial weight
    );

    // Initialize gauges
    await rwaGauge.grantRole(await rwaGauge.CONTROLLER_ROLE(), owner.address);
    await raacGauge.grantRole(await raacGauge.CONTROLLER_ROLE(), owner.address);
  });

  describe("Weight Management", () => {
    beforeEach(async () => {
      //await veRAACToken.mint(user1.address, ethers.parseEther("1000"));
      //await veRAACToken.mint(user2.address, ethers.parseEther("500"));
    });

    it("should calculate correct initial weights", async () => {
      const weight = await gaugeController.getGaugeWeight(
        await rwaGauge.getAddress()
      );
      expect(weight).to.equal(0);
    });

    it("should apply boost correctly", async () => {
      //c this test is wrong as no boost is applied. this is just a normal vote. i need to look into this boost mechanics and see how to exploit
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      //c user 1 locks raac tokens to gain veRAAC voting power
      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      const weight1 = await gaugeController.getGaugeWeight(
        await rwaGauge.getAddress()
      );
      console.log("Weight", weight1);

      const oldweight = await gaugeController.userGaugeVotes(
        user1.address,
        await rwaGauge.getAddress()
      );
      console.log("Old Weight", oldweight);

      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000);

      const newweightVotes = await gaugeController.userGaugeVotes(
        user1.address,
        await rwaGauge.getAddress()
      );
      const newWeight = (newweightVotes * user1bal) / BigInt(10000);
      console.log("New Weight", newWeight);

      const weight = await gaugeController.getGaugeWeight(
        await rwaGauge.getAddress()
      );
      console.log("Weight", weight);
      expect(weight).to.be.gt(0);

      //c the fact that this passes means that there has been no boost applied so this test is wrong
      assert(newWeight == weight);
    });

    it("should respect maximum weight limits", async () => {
      await expect(
        gaugeController
          .connect(user1)
          .vote(await rwaGauge.getAddress(), WEIGHT_PRECISION + 1)
      ).to.be.revertedWithCustomError(gaugeController, "InvalidWeight");
    });
  });

  describe("Period Management", () => {
    beforeEach(async () => {
      // await veRAACToken.mint(user1.address, ethers.parseEther("1000")); //c commented out for testing purposes

      // Align to period boundary
      const currentTime = BigInt(await time.latest());
      const nextPeriodStart =
        (currentTime / BigInt(MONTH) + 1n) * BigInt(MONTH);
      await time.setNextBlockTimestamp(Number(nextPeriodStart));
      await network.provider.send("evm_mine");
    });

    it("should handle RWA monthly periods", async () => {
      // Set initial gauge weight through voting
      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000);

      // Get initial period
      const initialPeriod = await gaugeController.gaugePeriods(
        await rwaGauge.getAddress()
      );

      // Move time forward by a month plus buffer
      await time.increase(MONTH + 1);
      await network.provider.send("evm_mine");

      // Update period
      await gaugeController.updatePeriod(await rwaGauge.getAddress());

      // Get updated period
      const period = await gaugeController.gaugePeriods(
        await rwaGauge.getAddress()
      );
      expect(period.totalDuration).to.equal(MONTH);
      expect(period.startTime).to.be.gt(initialPeriod.startTime);
    });

    it("should handle RAAC weekly periods", async () => {
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      await gaugeController
        .connect(user1)
        .vote(await raacGauge.getAddress(), 5000);

      // Get initial period
      const initialPeriod = await gaugeController.gaugePeriods(
        await raacGauge.getAddress()
      );

      // Move time forward by a week plus buffer
      await time.increase(WEEK + 1);
      await network.provider.send("evm_mine");

      await gaugeController.updatePeriod(await raacGauge.getAddress());

      // Get updated period
      const period = await gaugeController.gaugePeriods(
        await raacGauge.getAddress()
      );
      expect(period.totalDuration).to.equal(WEEK);
      expect(period.startTime).to.be.gt(initialPeriod.startTime);
    });

    it("user with no voting power can vote", async () => {
      //c setup user 1 to lock raac tokens to enable guage voting
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      //c user 1 locks raac tokens to gain veRAAC voting power
      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      //c let user1's duration run out so their voting power is 0
      await time.increase(duration + 1);
      const user1votingPower = await veRAACToken.getVotingPower(user1.address);
      console.log("User 1 voting power", user1votingPower);

      await gaugeController
        .connect(user1)
        .vote(await raacGauge.getAddress(), 5000);

      //c with user 1 voting power at 0, they are still about to use their full voting power to vote on the gauge
      const user1votes = await gaugeController.userGaugeVotes(
        user1.address,
        await raacGauge.getAddress()
      );
      console.log("User 1 votes", user1votes);
      assert(user1votes > 0);
    });

    it("user can use same voting power to vote on multiple gauges", async () => {
      //c for testing purposes
      //c setup user 1 to lock raac tokens to enable gauge voting
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      //c user 1 locks raac tokens to gain veRAAC voting power
      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      //c user1 votes on raac gauge
      await gaugeController
        .connect(user1)
        .vote(await raacGauge.getAddress(), 5000);

      //c get weight of user1's vote on raac gauge
      const user1RAACvotes = await gaugeController.userGaugeVotes(
        user1.address,
        await raacGauge.getAddress()
      );
      console.log("User 1 votes", user1RAACvotes);

      //c user1 votes on rwa gauge
      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000);

      //c get weight of user1's vote on rwa gauge
      const user1RWAvotes = await gaugeController.userGaugeVotes(
        user1.address,
        await rwaGauge.getAddress()
      );
      console.log("User 1 votes", user1RWAvotes);
      assert(user1RAACvotes == user1RWAvotes);
    });

    it("user can prematurely call distributeRewards immediately after voting and send all rewards to any gauge they want", async () => {
      //c for testing purposes
      //c setup user 1 to lock raac tokens to enable gauge voting
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      //c user 1 locks raac tokens to gain veRAAC voting power
      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      //c user1 votes on raac gauge
      await gaugeController
        .connect(user1)
        .vote(await raacGauge.getAddress(), 5000);

      //c make sure the gauge has some rewards to distribute
      await rewardToken.mint(
        raacGauge.getAddress(),
        ethers.parseEther("10000000000")
      );

      //c get weight of user1's vote on raac gauge
      const user1RAACvotes = await gaugeController.userGaugeVotes(
        user1.address,
        await raacGauge.getAddress()
      );
      console.log("User 1 votes", user1RAACvotes);

      //c allow some time to pass for rewards to accrue
      const DAY = 24 * 3600;
      await time.increase(DAY + 1);

      //c user1 calls distribute rewards and sends all rewards to rwa gauge
      const tx = await gaugeController
        .connect(user1)
        .distributeRewards(await raacGauge.getAddress());

      const totalWeight = await gaugeController.getTotalWeight();
      console.log("Total Weight", totalWeight);

      const calcReward = await gaugeController._calculateReward(
        await raacGauge.getAddress()
      );
      console.log("Calc Reward", calcReward);

      const txReceipt = await tx.wait();
      const eventLogs = txReceipt.logs;
      let reward;

      for (let log of eventLogs) {
        if (log.fragment && log.fragment.name === "RewardDistributed") {
          reward = log.args[2];
          break;
        }
      }
      console.log("Reward", reward);

      //c proof that all rewards were sent to rwa gauge
      const period = await raacGauge.periodState();
      const distributed = period.distributed;
      console.log("Distributed", distributed);

      assert(reward == distributed);
    });

    it("user can prematurely call distributeRewards immediately after voting and send all rewards to any gauge they want", async () => {
      //c for testing purposes
      //c setup user 1 to lock raac tokens to enable gauge voting
      const INITIAL_MINT = ethers.parseEther("1000000");
      await raacToken.mint(user1.address, INITIAL_MINT);
      await raacToken
        .connect(user1)
        .approve(await veRAACToken.getAddress(), MaxUint256);

      //c user 1 locks raac tokens to gain veRAAC voting power
      await veRAACToken.connect(user1).lock(INITIAL_MINT, duration);
      const user1bal = await veRAACToken.balanceOf(user1.address);
      console.log("User 1 balance", user1bal);

      //c user1 votes on raac gauge
      await gaugeController
        .connect(user1)
        .vote(await raacGauge.getAddress(), 5000);

      //c make sure the gauge has some rewards to distribute
      await rewardToken.mint(
        raacGauge.getAddress(),
        ethers.parseEther("10000000000")
      );

      //c get weight of user1's vote on raac gauge
      const user1RAACvotes = await gaugeController.userGaugeVotes(
        user1.address,
        await raacGauge.getAddress()
      );
      console.log("User 1 votes", user1RAACvotes);

      //c allow some time to pass for rewards to accrue
      const DAY = 24 * 3600;
      await time.increase(DAY + 1);

      //c user1 calls distribute rewards and sends all rewards to rwa gauge
      const tx = await gaugeController
        .connect(user1)
        .distributeRewards(await raacGauge.getAddress());

      const totalWeight = await gaugeController.getTotalWeight();
      console.log("Total Weight", totalWeight);

      const calcReward = await gaugeController._calculateReward(
        await raacGauge.getAddress()
      );
      console.log("Calc Reward", calcReward);

      const txReceipt = await tx.wait();
      const eventLogs = txReceipt.logs;
      let reward;

      for (let log of eventLogs) {
        if (log.fragment && log.fragment.name === "RewardDistributed") {
          reward = log.args[2];
          break;
        }
      }
      console.log("Reward", reward);

      //c proof that all rewards were sent to rwa gauge
      const period = await raacGauge.periodState();
      const distributed = period.distributed;
      console.log("Distributed", distributed);

      assert(reward == distributed);
    });

    it("should enforce period boundaries", async () => {
      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000);

      // Move time forward past first period
      await time.increase(MONTH + 1);
      await network.provider.send("evm_mine");

      // First update should succeed
      await gaugeController.updatePeriod(await rwaGauge.getAddress());

      // Immediate update should fail
      await expect(
        gaugeController.updatePeriod(await rwaGauge.getAddress())
      ).to.be.revertedWithCustomError(gaugeController, "PeriodNotElapsed");

      // Move past period
      await time.increase(MONTH + 1);
      await network.provider.send("evm_mine");

      // Should succeed now
      await gaugeController.updatePeriod(await rwaGauge.getAddress());
    });
  });

  describe("Emergency Controls", () => {
    it("should pause emissions", async () => {
      await gaugeController.connect(emergencyAdmin).setEmergencyPause(true);
      expect(await gaugeController.paused()).to.be.true;
    });

    it("should resume emissions", async () => {
      await gaugeController.connect(emergencyAdmin).setEmergencyPause(true);
      await gaugeController.connect(emergencyAdmin).setEmergencyPause(false);
      expect(await gaugeController.paused()).to.be.false;
    });

    it("should respect admin roles", async () => {
      await expect(
        gaugeController.connect(user1).setEmergencyPause(true)
      ).to.be.revertedWithCustomError(gaugeController, "UnauthorizedCaller");
    });
  });

  describe("Integration Tests", () => {
    it("should integrate with veRAAC voting power", async () => {
      await veRAACToken.mint(user1.address, ethers.parseEther("1000"));
      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000);

      const userVote = await gaugeController.userGaugeVotes(
        user1.address,
        await rwaGauge.getAddress()
      );
      expect(userVote).to.equal(5000);
    });

    it("should handle boost calculations", async () => {
      // Setup boost parameters first
      const BOOST_PARAMS = {
        maxBoost: 25000n, // 2.5x max boost
        minBoost: 10000n, // 1x min boost
        boostWindow: BigInt(7 * 24 * 3600), // 1 week
        baseWeight: ethers.parseEther("1"),
        totalVotingPower: 0n,
        totalWeight: 0n,
      };

      // Setup initial conditions with safer numbers
      const amount = ethers.parseEther("100");
      const userBalance = ethers.parseEther("1000");
      const totalSupply = ethers.parseEther("10000");

      // Setup veToken balances and total supply with exact amounts
      await veRAACToken.mint(user1.address, userBalance);
      await veRAACToken.mint(owner.address, totalSupply - userBalance);

      // Set gauge weight (gauge is already added in beforeEach)
      await gaugeController
        .connect(user1)
        .vote(await rwaGauge.getAddress(), 5000); // 50% weight

      // Align to period boundary and ensure enough time has passed
      const currentTime = BigInt(await time.latest());
      const nextPeriodStart =
        (currentTime / BigInt(MONTH) + 2n) * BigInt(MONTH);
      await time.setNextBlockTimestamp(Number(nextPeriodStart));
      await network.provider.send("evm_mine");

      // Move time forward to allow period update
      await time.increase(MONTH + 1);
      await network.provider.send("evm_mine");

      await gaugeController.updatePeriod(await rwaGauge.getAddress());

      // Calculate boost using library
      const [boostBasisPoints, boostedAmount] =
        await gaugeController.calculateBoost(
          user1.address,
          await rwaGauge.getAddress(),
          amount
        );

      // console.log('Amount', ethers.formatEther(amount)); //100000000000000000000 -> 100
      // console.log('Boosted Amount', ethers.formatEther(boostedAmount)); //11500000000000000000 -> 11.5
      // console.log('Boost Basis Points', boostBasisPoints.toString()); //1500 -> 1500

      // Verify boost calculations with proper BigNumber comparisons
      expect(boostBasisPoints).to.be.gte(BOOST_PARAMS.minBoost); // At least 1x
      expect(boostBasisPoints).to.be.lte(BOOST_PARAMS.maxBoost); // Max 2.5x
      expect(boostedAmount).to.be.gte(amount);
      expect(boostedAmount).to.be.lte((BigInt(amount) * 125n) / 100n);
    });
  });
});
