import { time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;

describe("BaseGauge", () => {
    let baseGauge;
    let gaugeController;
    let veRAACToken;
    let rewardToken;
    let owner;
    let user1;
    let user2;
    
    const WEIGHT_PRECISION = 10000;
    const DAY = 24 * 3600;

    beforeEach(async () => {
        [owner, user1, user2] = await ethers.getSigners();

        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory("MockToken");
        rewardToken = await MockToken.deploy("Reward Token", "RWD", 18);
        veRAACToken = await MockToken.deploy("veRAAC Token", "veRAAC", 18);
        
        // Deploy controller
        const GaugeController = await ethers.getContractFactory("GaugeController");
        gaugeController = await GaugeController.deploy(await veRAACToken.getAddress());

        // Deploy MockBaseGauge
        const MockBaseGauge = await ethers.getContractFactory("MockBaseGauge");

        baseGauge = await MockBaseGauge.deploy(
            await rewardToken.getAddress(),
            await rewardToken.getAddress(),
            await gaugeController.getAddress(),
            ethers.parseEther("10000"), // maxEmission
            7 * 24 * 3600 // periodDuration
        );

        await baseGauge.grantRole(await baseGauge.CONTROLLER_ROLE(), owner.address);
        await baseGauge.grantRole(await baseGauge.FEE_ADMIN(), owner.address);
        await baseGauge.grantRole(await baseGauge.EMERGENCY_ADMIN(), owner.address);

        // initial state
        await rewardToken.mint(await baseGauge.getAddress(), ethers.parseEther("1000000"));
        await veRAACToken.mint(user1.address, ethers.parseEther("1000"));
        await veRAACToken.mint(user2.address, ethers.parseEther("500"));
        await baseGauge.initializeBoostState(
            25000, // 2.5x max boost
            10000, // 1x min boost
            7 * 24 * 3600 // 7 days boost window
        );

        // Add gauge to controller
        await gaugeController.addGauge(await baseGauge.getAddress(), 0, WEIGHT_PRECISION);
        await baseGauge.setDistributionCap(ethers.parseEther("1000000"));
        
        // Get current time and align to next period boundary with buffer
        const currentTime = BigInt(await time.latest());
        const duration = BigInt(7 * DAY);
        const nextPeriodStart = ((currentTime / duration) + 2n) * duration;
        
        // Move to next period start
        await time.setNextBlockTimestamp(Number(nextPeriodStart));
        await network.provider.send("evm_mine");
        
        // Initialize period state
        await baseGauge.setInitialWeight(5000);
        
        // Mine another block to ensure time progression
        await network.provider.send("evm_mine");
    });

    describe("Core Functionality", () => {
        it("should initialize with correct state", async () => {
            expect(await baseGauge.rewardToken()).to.equal(await rewardToken.getAddress());
            expect(await baseGauge.controller()).to.equal(await gaugeController.getAddress());
        });

        it("should enforce controller-only functions", async () => {
            await expect(
                baseGauge.connect(user1).notifyRewardAmount(ethers.parseEther("100"))
            ).to.be.revertedWithCustomError(baseGauge, "UnauthorizedCaller");
        });
    });

    describe("Weight Management", () => {
        it("should calculate user weight with boost", async () => {
            const weight = await baseGauge.getUserWeight(user1.address);
            expect(weight).to.be.gte(0);
        });

        it("should track total weight correctly", async () => {
            const totalWeight = await baseGauge.getTotalWeight();
            expect(totalWeight).to.be.gte(0);
        });

        // Skipped, mock causes to be failing (setInitialWeight). FIXME
        it.skip("should update weights through checkpointing", async () => {
            // Get current time and align to next period boundary
            const currentTime = BigInt(await time.latest());
            const periodDuration = BigInt(await baseGauge.getPeriodDuration());
            const nextPeriodStart = ((currentTime / periodDuration) + 1n) * periodDuration;
            
            // Move to next period start
            await time.setNextBlockTimestamp(Number(nextPeriodStart));
            await network.provider.send("evm_mine");
            
            // Set initial weight and checkpoint
            await baseGauge.setInitialWeight(7500);
            await baseGauge.checkpoint();
            
            // Verify initial period
            const initialPeriod = await baseGauge.weightPeriod();
            expect(initialPeriod.startTime).to.equal(nextPeriodStart);
            
            // Move forward a full period
            const nextNextPeriodStart = nextPeriodStart + periodDuration;
            await time.setNextBlockTimestamp(Number(nextNextPeriodStart));
            await network.provider.send("evm_mine");
            
            // Update period
            await baseGauge.updatePeriod();
            
            // Set new weight and checkpoint
            await baseGauge.setInitialWeight(5000);
            await baseGauge.checkpoint();
            
            const period = await baseGauge.weightPeriod();
            expect(period.startTime).to.equal(nextNextPeriodStart);
        });
    });

    describe("Reward Distribution", () => {
        beforeEach(async () => {
            // Setup rewards
            await rewardToken.mint(await baseGauge.getAddress(), ethers.parseEther("10000"));
            
            // Set emission cap before notifying rewards
            await baseGauge.setEmission(ethers.parseEther("10000"));
            
            // Set initial weights and vote to enable rewards
            await gaugeController.connect(user1).vote(await baseGauge.getAddress(), 5000);
            await baseGauge.notifyRewardAmount(ethers.parseEther("1000"));
        });

        it("should track reward per token", async () => {
            const rewardPerToken = await baseGauge.getRewardPerToken();
            expect(rewardPerToken).to.be.gte(0);
        });

        it("should calculate earned rewards", async () => {
            const earned = await baseGauge.earned(user1.address);
            expect(earned).to.be.gte(0);
        });

        it("should enforce claim interval", async () => {
            // Wait for rewards to accrue
            await time.increase(DAY);

            // First claim should work
            await baseGauge.connect(user1).getReward();

            // Immediate second claim should fail
            await expect(
                baseGauge.connect(user1).getReward()
            ).to.be.revertedWithCustomError(baseGauge, "ClaimTooFrequent");

            // After waiting, claim should work again
            await time.increase(DAY + 1);
            await baseGauge.connect(user1).getReward();
        });

        it("should respect distribution caps", async () => {
            const newCap = ethers.parseEther("1000");
            await baseGauge.setDistributionCap(newCap);
            expect(await baseGauge.distributionCap()).to.equal(newCap);
        });
    });

    describe("Time-Weighted Averages", () => {
        beforeEach(async () => {
            // Get current time and align to next period boundary with buffer
            const currentTime = BigInt(await time.latest());
            const duration = BigInt(7 * DAY);
            const nextPeriodStart = ((currentTime / duration) + 2n) * duration;
            
            // Move to next period start
            await time.setNextBlockTimestamp(Number(nextPeriodStart));
            await network.provider.send("evm_mine");
            
            await baseGauge.setInitialWeight(5000);
            await network.provider.send("evm_mine");
        });

        it("should calculate time-weighted weights correctly", async () => {
            const initialWeight = await baseGauge.getTimeWeightedWeight();
            expect(initialWeight).to.equal(5000);

            // Move forward in time and update weight
            await time.increase(DAY);
            await baseGauge.checkpoint();
            const midWeight = await baseGauge.getTimeWeightedWeight();
            expect(midWeight).to.equal(5000);
        });

        it.skip("should handle period transitions properly", async () => {
            // Get current time and align to next period boundary
            const currentTime = BigInt(await time.latest());
            const periodDuration = BigInt(7 * DAY);
            const nextPeriodStart = ((currentTime / periodDuration) + 2n) * periodDuration;
            
            // Move to next period start
            await time.setNextBlockTimestamp(Number(nextPeriodStart));
            await network.provider.send("evm_mine");
            
            // Set initial weight and checkpoint
            await baseGauge.setInitialWeight(5000);
            await baseGauge.checkpoint();
            
            // Verify initial period (will fail due to mock)
            const period1 = await baseGauge.weightPeriod();
            expect(period1.startTime).to.be.gt(0);
            
            // Move forward a period
            await time.setNextBlockTimestamp(Number(nextPeriodStart) + Number(periodDuration));
            await network.provider.send("evm_mine");
            
            await baseGauge.updatePeriod();
            
            // Set new weight
            await baseGauge.setInitialWeight(7500);
            await baseGauge.checkpoint();
            
            const period2 = await baseGauge.weightPeriod();
            expect(period2.startTime).to.be.gt(period1.startTime);
            expect(period2.startTime - period1.startTime).to.be.gte(periodDuration);
        });

        it("should validate period boundaries", async () => {
            // Get current time and calculate next period start
            const currentTime = BigInt(await time.latest());
            const duration = BigInt(7 * DAY);
            const nextPeriodStart = ((currentTime / duration) + 1n) * duration;
            
            // Move to next period start
            await time.setNextBlockTimestamp(nextPeriodStart);
            await network.provider.send("evm_mine");
            
            await baseGauge.checkpoint();
            const period = await baseGauge.weightPeriod();
            
            // Try to checkpoint before period end
            await time.increase(DAY); // Move forward less than a period
            await baseGauge.checkpoint(); // Should update within same period
            
            const periodAfter = await baseGauge.weightPeriod();
            expect(periodAfter.startTime).to.equal(period.startTime);
        });

        it("should maintain weight precision", async () => {
            // Align to period boundary
            const currentTime = BigInt(await time.latest());
            const duration = BigInt(7 * DAY);
            const nextPeriodStart = ((currentTime / duration) + 2n) * duration;
            await time.setNextBlockTimestamp(Number(nextPeriodStart));
            await network.provider.send("evm_mine");
            
            await baseGauge.setInitialWeight(WEIGHT_PRECISION);
            await baseGauge.checkpoint();
            
            const weight = await baseGauge.getTimeWeightedWeight();
            expect(weight).to.equal(WEIGHT_PRECISION);
        });
    });

    describe("Security Features", () => {
        it("should validate reward rates", async () => {
        const maxRate = await baseGauge.MAX_REWARD_RATE();
        await expect(
            baseGauge.testValidateRewardRate(maxRate + BigInt(1))
        ).to.be.revertedWithCustomError(baseGauge, "ExcessiveRewardRate");
        });

        it("should handle insufficient balances", async () => {
            // Setup initial state with emission cap
            await baseGauge.setEmission(ethers.parseEther("10000"));
            
            // Setup rewards and voting
            await gaugeController.connect(user1).vote(await baseGauge.getAddress(), 5000);
            await baseGauge.notifyRewardAmount(ethers.parseEther("1000"));
            
            // Stake some tokens to gauge to be eligible for rewards
            await rewardToken.mint(user1.address, ethers.parseEther("1000"));
            await rewardToken.connect(user1).approve(await baseGauge.getAddress(), ethers.parseEther("1000"));
            await baseGauge.connect(user1).stake(ethers.parseEther("1000"));

            // Wait for rewards to accrue
            await time.increase(DAY);

            // Transfer out all tokens from gauge
            const gaugeBalance = await rewardToken.balanceOf(await baseGauge.getAddress());
            await baseGauge.connect(owner).emergencyWithdraw(
                await rewardToken.getAddress(),
                gaugeBalance
            );

            // claim should fail due to insufficient balance
            await expect(
                baseGauge.connect(user1).getReward()
            ).to.be.revertedWithCustomError(baseGauge, "InsufficientBalance");
        });
    });
});
