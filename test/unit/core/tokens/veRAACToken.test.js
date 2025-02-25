import { assert, expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("veRAACToken", () => {
  let veRAACToken;
  let raacToken;
  let owner;
  let users;
  const { MaxUint256 } = ethers;

  const MIN_LOCK_DURATION = 365 * 24 * 3600; // 1 year
  const MAX_LOCK_DURATION = 1460 * 24 * 3600; // 4 years
  const INITIAL_MINT = ethers.parseEther("1000000");
  const BOOST_WINDOW = 7 * 24 * 3600; // 7 days
  const MAX_BOOST = 25000; // 2.5x
  const MIN_BOOST = 10000; // 1x

  async function initializeBoostIfNeeded() {
    const boostWindow = await veRAACToken.getBoostWindow();
    if (boostWindow == 0) {
      // await veRAACToken.initializeBoostCalculator(
      //     BOOST_WINDOW,
      //     MAX_BOOST,
      //     MIN_BOOST
      // );
    }
  }

  beforeEach(async () => {
    [owner, ...users] = await ethers.getSigners();
    console.log("Total signers:", users.length);

    // Deploy Mock RAAC Token
    const MockRAACToken = await ethers.getContractFactory("ERC20Mock");
    raacToken = await MockRAACToken.deploy("RAAC Token", "RAAC");
    await raacToken.waitForDeployment();

    // // Deploy RAACVoting library
    // const RAACVoting = await ethers.getContractFactory("RAACVoting");
    // const raacVotingLib = await RAACVoting.deploy();
    // await raacVotingLib.waitForDeployment();

    // // Deploy veRAACToken contract
    // const VeRAACToken = await ethers.getContractFactory("veRAACToken", {
    //     libraries: {
    //         RAACVoting: await raacVotingLib.getAddress(),
    //     },
    // });
    // Deploy veRAACToken contract directly without library linking
    const VeRAACToken = await ethers.getContractFactory("veRAACToken");
    veRAACToken = await VeRAACToken.deploy(await raacToken.getAddress());
    await veRAACToken.waitForDeployment();

    // Setup initial token balances and approvals
    for (const user of users.slice(0, 3)) {
      await raacToken.mint(user.address, INITIAL_MINT);
      await raacToken
        .connect(user)
        .approve(await veRAACToken.getAddress(), MaxUint256);
    }

    // Initialize boost calculator
    await initializeBoostIfNeeded();
  });

  describe("Lock Mechanism", () => {
    it("should allow users to create a lock with valid parameters", async () => {
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600; // 1 year

      // Create lock first
      const tx = await veRAACToken.connect(users[0]).lock(amount, duration);

      // Wait for the transaction
      const receipt = await tx.wait();

      // Find the LockCreated event
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "LockCreated"
      );
      // Get the actual unlock time from the event
      const actualUnlockTime = event.args[2];

      // Verify lock position
      const position = await veRAACToken.getLockPosition(users[0].address);
      expect(position.amount).to.equal(amount);
      expect(position.end).to.equal(actualUnlockTime);
      expect(position.power).to.be.gt(0);

      // Verify the unlock time is approximately duration seconds from now
      const currentTime = await time.latest();
      expect(actualUnlockTime).to.be.closeTo(currentTime + duration, 5); // Allow 5 seconds deviation
    });

    it("user cannot create lock via when previous period end time has elapsed", async () => {
      //c for testing purposes
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600; // 1 year

      // Create lock first
      const tx = await veRAACToken.connect(users[0]).lock(amount, duration);

      // Wait for the transaction
      await tx.wait();

      // Create another lock within same time frame but within same time frame as previous period
      await time.increase(24 * 3600); // 1 day

      const tx2 = await veRAACToken.connect(users[1]).lock(amount, duration);

      // Wait for the transaction
      await tx2.wait();

      // get boost state
      const boost = await veRAACToken.getBoostState();
      const boostwindow = boost.boostWindow;
      const startTime = boost.boostPeriod.startTime;
      const endTime = boost.boostPeriod.endTime;
      const lastUpdateTime = boost.boostPeriod.lastUpdateTime;
      const totalDuration = boost.boostPeriod.totalDuration;
      console.log("Boost Window: ", boostwindow);
      console.log("Start Time: ", startTime);
      console.log("End Time: ", endTime);
      console.log("Last Update Time: ", lastUpdateTime);
      console.log("Total Duration: ", totalDuration);

      // Create another lock within same time frame but within same time frame as previous period
      await time.increase(6 * 24 * 3600); //c allow 6 more days to pass so that the period has ended and a new one should be started

      //c confirm that the current timestamp is greater than or equal to the endtime of the previous period which means that when a user locks tokkens, a new global period should be started and no revert should occur
      const currentTime = await time.latest();
      console.log("Current Time: ", currentTime);
      assert(endTime == startTime + boostwindow);
      assert(
        currentTime >= endTime,
        "Current Time is less than end time of previous period"
      );
      await expect(
        veRAACToken.connect(users[2]).lock(amount, duration)
      ).to.be.revertedWithCustomError(veRAACToken, "PeriodNotElapsed");
    });

    it("check that balanceOf does not update with user bias which causes totalSupply skew", async () => {
      //c for testing purposes
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600; // 1 year

      // Create lock first for 2 users
      const tx = await veRAACToken.connect(users[0]).lock(amount, duration);
      const tx2 = await veRAACToken.connect(users[1]).lock(amount, duration);

      // Wait for the transactions
      await tx.wait();
      await tx2.wait();

      //c wait for some time to pass so the user's biases to change
      await time.increase(duration + 24 * 3600); // users voting power should be 0 as duration has passed

      //c get user biases
      const user0Bias = await veRAACToken.getVotingPower(users[0].address);
      const user1Bias = await veRAACToken.getVotingPower(users[1].address);
      const expectedTotalSupply = user0Bias + user1Bias;
      console.log("User 0 Bias: ", user0Bias);
      console.log("User 1 Bias: ", user1Bias);
      console.log("Expected Total Supply: ", expectedTotalSupply);

      //c get actual total supply
      const actualTotalSupply = await veRAACToken.totalSupply();
      console.log("Actual Total Supply: ", actualTotalSupply);

      //c due to improper tracking, expectedtotalsupply will be less than the actual total supply
      assert(expectedTotalSupply < actualTotalSupply);
    });

    it("should not allow locking with zero amount", async () => {
      const duration = 365 * 24 * 3600;
      await expect(
        veRAACToken.connect(users[0]).lock(0, duration)
      ).to.be.revertedWithCustomError(veRAACToken, "InvalidAmount");
    });

    it("should not allow locking with duration less than minimum", async () => {
      const amount = ethers.parseEther("1000");
      const duration = MIN_LOCK_DURATION - 1;

      await expect(
        veRAACToken.connect(users[0]).lock(amount, duration)
      ).to.be.revertedWithCustomError(veRAACToken, "InvalidLockDuration");
    });

    it("should not allow locking with duration more than maximum", async () => {
      const amount = ethers.parseEther("1000");
      const duration = MAX_LOCK_DURATION + 1;

      await expect(
        veRAACToken.connect(users[0]).lock(amount, duration)
      ).to.be.revertedWithCustomError(veRAACToken, "InvalidLockDuration");
    });

    it("should not allow locking more than maximum lock amount", async () => {
      const amount = ethers.parseEther("10000001"); // 10,000,001 tokens
      const duration = 365 * 24 * 3600; // 1 year

      await expect(
        veRAACToken.connect(users[0]).lock(amount, duration)
      ).to.be.revertedWithCustomError(veRAACToken, "AmountExceedsLimit");
    });

    it("should allow users to increase lock amount", async () => {
      const initialAmount = ethers.parseEther("1000");
      const additionalAmount = ethers.parseEther("500");
      const duration = 365 * 24 * 3600; // 1 year

      await veRAACToken.connect(users[0]).lock(initialAmount, duration);

      await expect(veRAACToken.connect(users[0]).increase(additionalAmount))
        .to.emit(veRAACToken, "LockIncreased")
        .withArgs(users[0].address, additionalAmount);

      const position = await veRAACToken.getLockPosition(users[0].address);
      expect(position.amount).to.equal(initialAmount + additionalAmount);
    });

    it("new bias skew in increase function", async () => {
      //c for testing purposes
      const initialAmount = ethers.parseEther("1000");
      const additionalAmount = ethers.parseEther("500");
      const duration = 365 * 24 * 3600; // 1 year

      await veRAACToken.connect(users[0]).lock(initialAmount, duration);

      //c wait for some time to pass so the user's biases to change
      await time.increase(duration / 2); //c half a year has passed

      //c get user biases
      const user0BiasPreIncrease = await veRAACToken.getVotingPower(
        users[0].address
      );
      console.log("User 0 Bias: ", user0BiasPreIncrease);

      //c calculate expected bias after increase taking the rate of decay of user's tokens into account
      const amount = user0BiasPreIncrease + additionalAmount;
      console.log("Amount: ", amount);

      const positionPreIncrease = await veRAACToken.getLockPosition(
        users[0].address
      );
      const positionEndTime = positionPreIncrease.end;
      console.log("Position End Time: ", positionEndTime);

      const currentTimestamp = await time.latest();
      const duration1 = positionEndTime - BigInt(currentTimestamp);
      console.log("Duration 1: ", duration1);

      const user0expectedBiasAfterIncrease =
        (amount * duration1) / (await veRAACToken.MAX_LOCK_DURATION());
      console.log(
        "Expected Bias After Increase: ",
        user0expectedBiasAfterIncrease
      );

      await veRAACToken.connect(users[0]).increase(additionalAmount);

      //c get actual user biases after increase
      const user0actualBiasPostIncrease = await veRAACToken.getVotingPower(
        users[0].address
      );
      console.log("User 0 Post Increase Bias: ", user0actualBiasPostIncrease);

      //c since the rate of decay was not taken into account when calculating the user's bias, the expected bias after increase will be less than the actual bias after increase which gives the user more voting power than expected which can be used to skew voting results and reward distribution
      assert(user0expectedBiasAfterIncrease < user0actualBiasPostIncrease);

      const position = await veRAACToken.getLockPosition(users[0].address);
      expect(position.amount).to.equal(initialAmount + additionalAmount);
    });

    it("2 users locking same amount with different methods end up with different voting power", async () => {
      //c for testing purposes
      const initialAmount = ethers.parseEther("1000");

      const duration = 365 * 24 * 3600; // 1 year

      //c user0 locks tokens using the lock function
      await veRAACToken.connect(users[0]).lock(initialAmount, duration);

      //c user 1 knows about the exploit and deposits only half the amount of user 0 for same duration
      await veRAACToken
        .connect(users[1])
        .lock(BigInt(initialAmount) / BigInt(2), duration);

      //c wait for some time to pass so the user's biases to change
      await time.increase(duration / 2); //c half a year has passed

      //c user1 waits half a year and then deposits the next half of the amount without adjusting their lock duration
      await veRAACToken
        .connect(users[1])
        .increase(BigInt(initialAmount) / BigInt(2));

      //c get user biases
      const user0BiasPostIncrease = await veRAACToken.getVotingPower(
        users[0].address
      );
      console.log("User 0 Bias: ", user0BiasPostIncrease);

      const user1BiasPostIncrease = await veRAACToken.getVotingPower(
        users[1].address
      );
      console.log("User 1 Bias: ", user1BiasPostIncrease);

      //c at this point, user0 and user1 should have the same voting power since they have the same amount of tokens locked for the same duration but this isnt the case due to the bug in the above test and user1 will end up with more tokens than user 0
      assert(user0BiasPostIncrease < user1BiasPostIncrease);
    });

    it("no max supply check when user is increasing lock amount", async () => {
      //c for testing purposes
      const initialAmount = ethers.parseEther("100000000");
      const initialLock = ethers.parseEther("1000");
      const increaseAmount = ethers.parseEther("9999000");

      const duration = 365 * 24 * 3600; // 1 year

      for (const user of users.slice(0, 21)) {
        await raacToken.mint(user.address, initialAmount);
        await raacToken
          .connect(user)
          .approve(await veRAACToken.getAddress(), MaxUint256);
        await veRAACToken.connect(user).lock(initialLock, duration);
        await veRAACToken.connect(user).increase(increaseAmount);
      }

      //c get total supply
      const totalSupply = await veRAACToken.totalSupply();
      const maxTotalSupply = await veRAACToken.MAX_TOTAL_SUPPLY();
      console.log("Total Supply: ", totalSupply);
      console.log("Max Total Supply: ", maxTotalSupply);

      //c the total supply will be more than the max due to the lack of total supply enforcement when a user increases their lock amount
      assert(totalSupply > maxTotalSupply);
    });

    it("should not allow increasing lock amount beyond maximum", async () => {
      const initialAmount = ethers.parseEther("5000000");
      const additionalAmount = ethers.parseEther("6000000");
      const duration = 365 * 24 * 3600;

      // Mint enough tokens for the test
      await raacToken.mint(users[0].address, initialAmount + additionalAmount);

      await veRAACToken.connect(users[0]).lock(initialAmount, duration);

      await expect(
        veRAACToken.connect(users[0]).increase(additionalAmount)
      ).to.be.revertedWithCustomError(veRAACToken, "AmountExceedsLimit");
    });

    it("should allow users to extend lock duration", async () => {
      const amount = ethers.parseEther("1000");
      const initialDuration = 365 * 24 * 3600; // 1 year
      const extensionDuration = 180 * 24 * 3600; // 6 months

      await veRAACToken.connect(users[0]).lock(amount, initialDuration);
      const currentTime = await time.latest();
      const newUnlockTime = currentTime + initialDuration + extensionDuration;

      await expect(veRAACToken.connect(users[0]).extend(extensionDuration))
        .to.emit(veRAACToken, "LockExtended")
        .withArgs(users[0].address, newUnlockTime);
    });

    it("should allow users to withdraw after lock expires", async () => {
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600; // 1 year

      await veRAACToken.connect(users[0]).lock(amount, duration);
      await time.increase(duration + 1);

      const balanceBefore = await raacToken.balanceOf(users[0].address);
      await expect(veRAACToken.connect(users[0]).withdraw())
        .to.emit(veRAACToken, "Withdrawn")
        .withArgs(users[0].address, amount);

      const balanceAfter = await raacToken.balanceOf(users[0].address);
      expect(balanceAfter - balanceBefore).to.equal(amount);
    });
  });

  describe("Voting Power Calculations", () => {
    it("should calculate voting power proportionally to lock duration", async () => {
      const amount = ethers.parseEther("1000");
      const shortDuration = 365 * 24 * 3600; // 1 year
      const longDuration = 730 * 24 * 3600; // 2 years

      await veRAACToken.connect(users[0]).lock(amount, shortDuration);
      await veRAACToken.connect(users[1]).lock(amount, longDuration);

      const shortPower = await veRAACToken.balanceOf(users[0].address);
      const longPower = await veRAACToken.balanceOf(users[1].address);

      expect(longPower).to.be.gt(shortPower);
    });

    it("should decay voting power linearly over time", async () => {
      const amount = ethers.parseEther("1000");
      console.log("Test Amount: ", amount);
      const duration = 365 * 24 * 3600; // 1 year
      console.log("Test Duration: ", duration);

      await veRAACToken.connect(users[0]).lock(amount, duration);
      const initialPower = await veRAACToken.getVotingPower(users[0].address);
      console.log("Test Initial Power: ", initialPower);

      await time.increase(duration / 2);

      // Explicitly get the voting power at the new timestamp
      const midPower = await veRAACToken.getVotingPower(users[0].address);
      console.log("Test Mid Power: ", midPower);

      expect(midPower).to.be.lt(initialPower);
      expect(midPower).to.be.gt(0);
    });
  });

  describe("Boost Calculations", () => {
    it("should update boost state on lock actions", async () => {
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600;

      // Create initial lock
      await veRAACToken.connect(users[0]).lock(amount, duration);

      // Get boost state
      const boostState = await veRAACToken.getBoostState();

      // Check boost is within expected range (10000 = 1x, 25000 = 2.5x)
      expect(boostState.minBoost).to.equal(10000); // 1x
      expect(boostState.maxBoost).to.equal(25000); // 2.5x

      // Get current boost for user
      const { boostBasisPoints, boostedAmount } =
        await veRAACToken.getCurrentBoost(users[0].address);

      console.log("Boost Basis Points: ", boostBasisPoints);
      console.log("Boosted Amount: ", boostedAmount);
      // Boost should be between min and max (in basis points)
      expect(boostBasisPoints).to.be.gte(10000); // At least 1x
      expect(boostBasisPoints).to.be.lte(25000); // At most 2.5x
    });
  });

  describe("Transfer Restrictions", () => {
    it("should prevent transfers of veRAAC tokens", async () => {
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600;

      await veRAACToken.connect(users[0]).lock(amount, duration);
      await expect(
        veRAACToken.connect(users[0]).transfer(users[1].address, amount)
      ).to.be.revertedWithCustomError(veRAACToken, "TransferNotAllowed");
    });
  });

  describe("Emergency Withdrawal", () => {
    const EMERGENCY_DELAY = 3 * 24 * 3600; // 3 days in seconds

    it("should allow users to withdraw during emergency", async () => {
      const amount = ethers.parseEther("1000");
      const duration = 365 * 24 * 3600;
      await raacToken.mint(users[0].address, amount);
      await raacToken
        .connect(users[0])
        .approve(await veRAACToken.getAddress(), amount);
      await veRAACToken.connect(users[0]).lock(amount, duration);

      // Schedule emergency withdraw action
      const EMERGENCY_WITHDRAW_ACTION = ethers.keccak256(
        ethers.toUtf8Bytes("enableEmergencyWithdraw")
      );
      await veRAACToken
        .connect(owner)
        .scheduleEmergencyAction(EMERGENCY_WITHDRAW_ACTION);

      // Wait for emergency delay
      await time.increase(EMERGENCY_DELAY);

      // Enable emergency withdraw
      await veRAACToken.connect(owner).enableEmergencyWithdraw();

      // Wait for emergency withdraw delay
      await time.increase(EMERGENCY_DELAY);

      // Get initial balances
      const initialBalance = await raacToken.balanceOf(users[0].address);

      // Perform emergency withdrawal
      await expect(veRAACToken.connect(users[0]).emergencyWithdraw())
        .to.emit(veRAACToken, "EmergencyWithdrawn")
        .withArgs(users[0].address, amount);

      // Verify balance changes
      const finalBalance = await raacToken.balanceOf(users[0].address);
      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("should not allow emergency withdraw if not enabled", async () => {
      await expect(
        veRAACToken.connect(users[0]).emergencyWithdraw()
      ).to.be.revertedWithCustomError(
        veRAACToken,
        "EmergencyWithdrawNotEnabled"
      );
    });

    it("should not allow non-owner to schedule emergency unlock", async () => {
      await expect(veRAACToken.connect(users[0]).scheduleEmergencyUnlock())
        .to.be.revertedWithCustomError(
          veRAACToken,
          "OwnableUnauthorizedAccount"
        )
        .withArgs(users[0].address);
    });

    it("should not allow emergency unlock execution before delay", async () => {
      await veRAACToken.connect(owner).scheduleEmergencyUnlock();

      await expect(
        veRAACToken.connect(owner).executeEmergencyUnlock()
      ).to.be.revertedWithCustomError(veRAACToken, "EmergencyDelayNotMet");
    });
  });

  describe("Event Emissions", () => {
    it("should emit correct events for all lock operations", async () => {
      const amount = ethers.parseEther("1000");
      const additionalAmount = ethers.parseEther("500");
      const duration = 365 * 24 * 3600;
      const extensionDuration = 180 * 24 * 3600;

      // Lock creation
      const tx = await veRAACToken.connect(users[0]).lock(amount, duration);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment?.name === "LockCreated"
      );
      const unlockTime = event.args[2];

      // Lock amount increase
      await expect(veRAACToken.connect(users[0]).increase(additionalAmount))
        .to.emit(veRAACToken, "LockIncreased")
        .withArgs(users[0].address, additionalAmount);

      // Lock duration extension
      const newUnlockTime = BigInt(unlockTime) + BigInt(extensionDuration);
      await expect(veRAACToken.connect(users[0]).extend(extensionDuration))
        .to.emit(veRAACToken, "LockExtended")
        .withArgs(users[0].address, newUnlockTime);
    });
  });

  describe("Error Handling", () => {
    it("should revert when trying to lock without enough RAAC balance", async () => {
      const amount = ethers.parseEther("9900000"); // Very large amount below max lock amount
      const duration = 365 * 24 * 3600;

      // User without any RAAC balance tries to lock
      const userWithoutBalance = users[3];

      // Approve first
      await raacToken
        .connect(userWithoutBalance)
        .approve(await veRAACToken.getAddress(), amount);

      // Attempt to lock - should fail due to insufficient balance
      await expect(
        veRAACToken.connect(userWithoutBalance).lock(amount, duration)
      )
        .to.be.revertedWithCustomError(
          raacToken, //error comes from the RAAC token contract but is the Erc20 default error
          "ERC20InsufficientBalance"
        )
        .withArgs(
          userWithoutBalance.address, // from
          0, // current balance
          amount // required amount
        );
    });

    it("should revert when trying to withdraw without an existing lock", async () => {
      await expect(
        veRAACToken.connect(users[1]).withdraw()
      ).to.be.revertedWithCustomError(veRAACToken, "LockNotFound");
    });

    it("should revert when trying to extend lock beyond maximum duration", async () => {
      const amount = ethers.parseEther("1000");
      const initialDuration = MAX_LOCK_DURATION - 100;
      const extensionDuration = 200;

      // First create a lock
      await raacToken.mint(users[0].address, amount);
      await raacToken
        .connect(users[0])
        .approve(await veRAACToken.getAddress(), amount);
      await veRAACToken.connect(users[0]).lock(amount, initialDuration);

      // Try to extend the lock duration
      await expect(
        veRAACToken.connect(users[0]).extend(extensionDuration)
      ).to.be.revertedWithCustomError(veRAACToken, "InvalidLockDuration");
    });

    it("should revert when trying to withdraw from non-existent lock", async () => {
      // Try to withdraw with an account that never created a lock
      await expect(
        veRAACToken.connect(users[2]).withdraw()
      ).to.be.revertedWithCustomError(veRAACToken, "LockNotFound");
    });
  });
});
