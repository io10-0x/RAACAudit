// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../../interfaces/core/governance/gauges/IGauge.sol";
import "../../../interfaces/core/governance/gauges/IGaugeController.sol";

import "../../../libraries/governance/BoostCalculator.sol";
import "../../../libraries/math/TimeWeightedAverage.sol";

/**
 * @title BaseGauge
 * @author RAAC Protocol Team
 * @notice Base implementation for RWA and RAAC gauges that handles reward distribution and boost calculations
 * @dev Abstract contract implementing core gauge functionality including:
 * - Reward distribution with boost multipliers (based on user weight)
 * - Time-weighted average tracking
 * - Access control and security features, emergency controls
 * - Staking functionality for reward tokens
 */
abstract contract BaseGauge is
    IGauge,
    ReentrancyGuard,
    AccessControl,
    Pausable
{
    using SafeERC20 for IERC20;
    using TimeWeightedAverage for TimeWeightedAverage.Period;

    /// @notice Token distributed as rewards
    IERC20 public immutable rewardToken;

    /// @notice Token that can be staked
    IERC20 public immutable stakingToken;

    /// @notice Controller contract managing gauge weights
    address public immutable controller;

    /// @notice Period for tracking time-weighted averages
    TimeWeightedAverage.Period public weightPeriod;

    /// @notice Mapping of user addresses to their reward state
    mapping(address => UserState) public userStates;

    /// @notice Current rate of reward distribution
    uint256 public rewardRate;

    /// @notice Last time rewards were updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated rewards per token
    uint256 public rewardPerTokenStored;

    /// @notice Maximum allowed slippage (1%)
    uint256 public constant MAX_SLIPPAGE = 100;

    /// @notice Precision for weight calculations
    uint256 public constant WEIGHT_PRECISION = 10000;

    /// @notice Maximum reward rate to prevent overflow
    uint256 public constant MAX_REWARD_RATE = 1000000e18;

    /// @notice Mapping of last claim times per user
    mapping(address => uint256) public lastClaimTime;

    /// @notice Minimum interval between reward claims
    uint256 public constant MIN_CLAIM_INTERVAL = 1 days;

    /// @notice State for boost calculations
    BoostCalculator.BoostState public boostState;

    /// @notice Cap on reward distribution amount
    uint256 public distributionCap;

    /// @notice Role for controller functions
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    /// @notice Role for emergency admin functions
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");

    /// @notice Role for fee admin functions
    bytes32 public constant FEE_ADMIN = keccak256("FEE_ADMIN");

    /// @notice Staking state variables
    uint256 private _totalSupply; // Total staked amount
    mapping(address => uint256) private _balances; // User balances

    /// @notice Total votes across all users
    uint256 public totalVotes;

    /// @notice Current period state
    PeriodState public periodState;

    /// @notice User voting data
    mapping(address => VoteState) public userVotes;

    // Modifiers

    /**
     * @notice Restricts function to controller role
     */
    modifier onlyController() {
        if (!hasRole(CONTROLLER_ROLE, msg.sender)) revert UnauthorizedCaller();
        _;
    }

    /**
     * @notice Updates rewards before executing function
     * @param account Address to update rewards for
     */
    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    /**
     * @notice Initializes the gauge contract
     * @param _rewardToken Address of reward token
     * @param _stakingToken Address of staking token
     * @param _controller Address of controller contract
     * @param _maxEmission Maximum emission amount
     * @param _periodDuration Duration of the period
     */
    constructor(
        //c remember that this is an abstract contract. it is never deployed. it is only designed to be inherited from by other contracts that will be used as guages like RAACGauge and RWA Gauge
        address _rewardToken,
        address _stakingToken,
        address _controller,
        uint256 _maxEmission,
        uint256 _periodDuration
    ) {
        rewardToken = IERC20(_rewardToken);
        stakingToken = IERC20(_stakingToken);
        controller = _controller;

        // Initialize roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTROLLER_ROLE, _controller);

        // Initialize boost parameters
        boostState.maxBoost = 25000; // 2.5x
        boostState.minBoost = 1e18; //bug there is an overflow here . if the controller doesnt call setBoostParameters, then the maxBoost will be 25000 and the minBoost will be 1e18 and in updateReward, boostcalculator::calculateBoost will be called with these values and in that function, the maxboost is subtracted by the min boost so there will be an overflow there
        boostState.boostWindow = 7 days;

        uint256 currentTime = block.timestamp;
        uint256 nextPeriod = ((currentTime / _periodDuration) *
            _periodDuration) + _periodDuration; //q so what happens if rewards are distributed when a period hasnt started ?? is there any way to check if rewards have already been distributed in that period ??

        //q why tf is the current time multiplied and then divided by the same value, this is just inviting precision loss and what for ??

        // Initialize period state
        periodState.periodStartTime = nextPeriod;
        periodState.emission = _maxEmission;
        TimeWeightedAverage.createPeriod(
            periodState.votingPeriod,
            nextPeriod,
            _periodDuration,
            0,
            10000 // VOTE_PRECISION
        );
    }

    // Internal functions

    /**
     * @notice Updates reward state for an account
     * @dev Calculates and updates reward state including per-token rewards
     * @param account Address to update rewards for
     */
    function _updateReward(address account) internal {
        rewardPerTokenStored = getRewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            UserState storage state = userStates[account];
            state.rewards = earned(account);
            state.rewardPerTokenPaid = rewardPerTokenStored; //c this reward per token paid is the stored reward per token value for user as per the natspec in igauge.sol
            state.lastUpdateTime = block.timestamp;
            emit RewardUpdated(account, state.rewards);
        }
    }

    /**
     * @notice Updates weights for time-weighted average calculation
     * @dev Creates new period or updates existing one with new weight
     * @param newWeight New weight value to record
     */
    function _updateWeights(uint256 newWeight) internal {
        uint256 currentTime = block.timestamp;
        uint256 duration = getPeriodDuration();

        if (weightPeriod.startTime == 0) {
            // For initial period, start from next period boundary
            uint256 nextPeriodStart = ((currentTime / duration) + 1) * duration;
            TimeWeightedAverage.createPeriod(
                weightPeriod,
                nextPeriodStart,
                duration,
                newWeight,
                WEIGHT_PRECISION
            );
        } else {
            // For subsequent periods, ensure we're creating a future period
            uint256 nextPeriodStart = ((currentTime / duration) + 1) * duration;
            TimeWeightedAverage.createPeriod(
                weightPeriod,
                nextPeriodStart,
                duration,
                newWeight,
                WEIGHT_PRECISION
            );
        }
    }

    /**
     * @notice Gets base weight for an account
     * @dev Virtual function to be implemented by child contracts
     * @param account Address to get weight for
     * @return Base weight value
     */
    function _getBaseWeight(
        address account
    ) internal view virtual returns (uint256) {
        return IGaugeController(controller).getGaugeWeight(address(this));
    }

    /**
     * @notice Applies boost multiplier to base weight
     * @dev Calculates boost based on veToken balance and parameters
     * @param account Address to calculate boost for
     * @param baseWeight Base weight to apply boost to
     * @return Boosted weight value
     */
    function _applyBoost(
        address account,
        uint256 baseWeight
    ) internal view virtual returns (uint256) {
        if (baseWeight == 0) return 0;

        IERC20 veToken = IERC20(IGaugeController(controller).veRAACToken());
        uint256 veBalance = veToken.balanceOf(account);
        uint256 totalVeSupply = veToken.totalSupply();

        // Create BoostParameters struct from boostState
        BoostCalculator.BoostParameters memory params = BoostCalculator
            .BoostParameters({
                maxBoost: boostState.maxBoost,
                minBoost: boostState.minBoost,
                boostWindow: boostState.boostWindow,
                totalWeight: boostState.totalWeight,
                totalVotingPower: boostState.totalVotingPower,
                votingPower: boostState.votingPower
            });

        uint256 boost = BoostCalculator.calculateBoost(
            veBalance,
            totalVeSupply,
            params
        );

        return (baseWeight * boost) / 1e18;
    }

    // External functions

    /**
     * @notice Stakes tokens in the gauge
     * @param amount Amount to stake
     */
    function stake(
        uint256 amount
    ) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert InvalidAmount();
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraws staked tokens
     * @param amount Amount to withdraw
     */
    function withdraw(
        uint256 amount
    ) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert InvalidAmount();
        if (_balances[msg.sender] < amount) revert InsufficientBalance();
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Gets balance of an account
     * @param account Address to check balance for
     * @return Account balance
     */
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Gets total supply
     * @return Total supply value
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Sets emergency pause state
     * @param paused True to pause, false to unpause
     */
    function setEmergencyPaused(bool paused) external {
        if (!hasRole(EMERGENCY_ADMIN, msg.sender)) revert UnauthorizedCaller();
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    /**
     * @notice Sets cap on reward distribution
     * @param newCap New distribution cap value
     */
    function setDistributionCap(uint256 newCap) external {
        if (!hasRole(FEE_ADMIN, msg.sender)) revert UnauthorizedCaller();
        distributionCap = newCap;
        emit DistributionCapUpdated(newCap);
    }

    /**
     * @notice Claims accumulated rewards
     * @dev Transfers earned rewards to caller
     */
    function getReward()
        external
        virtual
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        if (block.timestamp - lastClaimTime[msg.sender] < MIN_CLAIM_INTERVAL) {
            revert ClaimTooFrequent();
        }

        lastClaimTime[msg.sender] = block.timestamp;
        UserState storage state = userStates[msg.sender];
        uint256 reward = state.rewards;

        if (reward > 0) {
            state.rewards = 0;

            uint256 balance = rewardToken.balanceOf(address(this));
            if (reward > balance) {
                revert InsufficientBalance();
            }

            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Notifies contract of reward amount
     * @dev Updates reward rate based on new amount
     * @param amount Amount of rewards to distribute
     */
    function notifyRewardAmount(
        uint256 amount
    ) external override onlyController updateReward(address(0)) {
        if (amount > periodState.emission) revert RewardCapExceeded();
        //c so if the reward sent by the gauge is more than the emission cap, the notifyReward function will revert

        //c there are no checks to make sure that rewards are distributed once in a period. this means that the gauge can send rewards multiple times in a period and the notifyReward function will not revert. there is a check in the notifyReward function to make sure that the total rewards distributed in a period is not more than the emission cap no matter how many times rewards are distributed so i can assume that they assume that they allow the gauge to be able to send rewards multiple times in a period
        rewardRate = notifyReward(
            periodState,
            amount,
            periodState.emission,
            getPeriodDuration()
        );
        periodState.distributed += amount;

        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate * getPeriodDuration() > balance) {
            revert InsufficientRewardBalance();
        } //c need to check if there is some sort of timeout in the gaugecontroller that stops it from sending rewards to the gauge if it has already sent rewards to the gauge in the same period because if that is the case, then there is a bug here because this revert can get hit everytime

        lastUpdateTime = block.timestamp;
        emit RewardNotified(amount);
    }

    /**
     * @notice Notifies about new reward amount
     * @param state Period state to update
     * @param amount Reward amount
     * @param maxEmission Maximum emission allowed
     * @param periodDuration Duration of the period
     * @return newRewardRate Calculated reward rate
     */
    function notifyReward(
        PeriodState storage state,
        uint256 amount,
        uint256 maxEmission,
        uint256 periodDuration
    ) internal view returns (uint256) {
        if (amount > maxEmission) revert RewardCapExceeded();
        if (amount + state.distributed > state.emission) {
            revert RewardCapExceeded();
        } //c if the total rewards distributed in the period is more than the emission cap, the notifyReward function will revert

        uint256 rewardRate = amount / periodDuration; //c gets reward rate per second
        if (rewardRate == 0) revert ZeroRewardRate();

        return rewardRate;
    }

    /**
     * @notice Emergency withdrawal of tokens
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Allows users to vote on direction
     * @param direction Direction in basis points (0-10000)
     */
    function voteDirection(
        uint256 direction //q what does this direction actually do ?? see comment below to show that it really doesnt do anything
    ) public whenNotPaused updateReward(msg.sender) {
        if (direction > 10000) revert InvalidWeight();

        uint256 votingPower = IERC20(IGaugeController(controller).veRAACToken())
            .balanceOf(msg.sender); //bug REPORTED in gaugecontroller::vote balanceOf does not take rate of decay into account so this is not the correct way to get voting power and a user who's lock has ended and should have no voting power can still vote
        if (votingPower == 0) revert NoVotingPower();

        //bug REPORTED in gaugecontroller::vote a user can vote for as many gauges as they want because votingpower is not locked to the gauge.

        totalVotes = processVote(
            userVotes[
                msg.sender
            ] /*c so this mapping maps the user address to their vote state. the vote state is a struct which contains the following:
             struct VoteState {
        uint256 direction;     // Vote direction
        uint256 weight;        // Vote weight
        uint256 timestamp;     // Vote timestamp
    } so when this mapping is passed to the processVote function, it updates the direction, weight and timestamp of the vote state for the user as you will see below
            */,
            direction,
            votingPower,
            totalVotes
        );
        emit DirectionVoted(msg.sender, direction, votingPower);
    } //c i have established that currently, this emission direction doesnt do anything. although it is extensively tested in raacgauge.test.js, the idea is that the emission direction should have an effect on the emissions sent to the users in each period but it really doesnt do anything. To see this, go into raacgauge.test.js and go into the "Reward Distribution" describe block and you will see that this function is used in the beforeEach for whatever reason. If you run the "should distribute rewards correctly" test in that describe block and log the amount of rewards paid out and then comment out the voteDirection function in the beforeEach, you will see that the amount of rewards paid out is the same. This is because the voteDirection function does not do anything. Good thing all the bugs i raised in this function are done again in gaugecontroller::vote so happy days lolllllll

    /**
     * @notice Processes a vote for direction
     * @param vote Vote state to update
     * @param direction New vote direction
     * @param votingPower Voter's voting power
     * @param totalVotes Total votes to update
     * @return newTotalVotes Updated total votes
     */
    function processVote(
        VoteState storage vote,
        uint256 direction,
        uint256 votingPower,
        uint256 totalVotes
    ) internal returns (uint256) {
        if (direction > 10000) revert InvalidWeight();
        if (votingPower == 0) revert NoVotingPower();

        uint256 newTotalVotes = totalVotes - vote.weight + votingPower; //q can i cause an underflow here??

        //c the idea is that if a user votes again, the previous vote is removed and the new vote is added. so the total votes is updated by removing the previous vote and adding the new vote

        vote.direction = direction;
        vote.weight = votingPower;
        vote.timestamp = block.timestamp;

        return newTotalVotes;
    }

    /**
     * @notice Updates the period and calculates new weights
     */
    function updatePeriod() external override onlyController {
        uint256 currentTime = block.timestamp;
        uint256 periodEnd = periodState.periodStartTime + getPeriodDuration();
        //c this is exactly what happens in boostcalculator::updateBoostPeriod. This is the same check that happens for the period end. So

        if (currentTime < periodEnd) {
            revert PeriodNotElapsed();
        }

        uint256 periodDuration = getPeriodDuration();
        // Calculate average weight for the ending period
        uint256 avgWeight = periodState.votingPeriod.calculateAverage(
            periodEnd
        ); //bug this value can be bigger than the max emissions for gauges. see MAX_WEEKLY_EMISSION in raacGauge.sol

        // Calculate the start of the next period (ensure it's in the future)
        uint256 nextPeriodStart = ((currentTime / periodDuration) + 2) *
            periodDuration; //q why does the next period start the moment this function is called ?? so nextPeriodStart will always be greater than current time. so users will have to wait for nextperiodstart - current time to be able to claim rewards again ?? why is that. this is answered in my comments below setinitialweight function

        // Reset period state
        periodState.distributed = 0;
        periodState.periodStartTime = nextPeriodStart;

        // Create new voting period
        TimeWeightedAverage.createPeriod(
            periodState.votingPeriod,
            nextPeriodStart,
            periodDuration,
            avgWeight,
            WEIGHT_PRECISION
        );
    }

    /**
     * @notice Sets emission cap for the period
     * @param emission New emission amount
     */
    function setEmission(uint256 emission) external onlyController {
        //c note that this only controller modifier does not imply the gauge controller but whichever address has the controller role
        if (emission > periodState.emission) revert RewardCapExceeded();
        periodState.emission = emission;
        emit EmissionUpdated(emission);
    }

    /**
     * @notice Sets initial weight for the gauge
     * @param weight Initial weight value
     */
    function setInitialWeight(uint256 weight) external onlyController {
        uint256 periodDuration = getPeriodDuration();
        uint256 currentTime = block.timestamp;
        uint256 nextPeriodStart = ((currentTime / periodDuration) + 2) *
            periodDuration;

        TimeWeightedAverage.createPeriod(
            periodState.votingPeriod,
            nextPeriodStart,
            periodDuration,
            weight,
            10000 // WEIGHT_PRECISION
        );

        periodState.periodStartTime = nextPeriodStart;
    } /*c this function is used to create a new period that is 2 weeks from the currenttime. How do i know this ?? well lets see what nextPeriod = ((currentTime / _periodDuration) * _periodDuration) + _periodDuration; actually does. 

    Let’s go through the code step by step:


        uint256 nextPeriodStart = ((currentTime / periodDuration) + 2) * periodDuration;

        currentTime / periodDuration:

        This divides the current timestamp (currentTime) by the length of a period (periodDuration).

        For example, if currentTime is 1696118400 (October 1, 2023, 00:00:00 UTC) and periodDuration is 604800 (7 days in seconds), the result is:

        
        1696118400 / 604800 = 2804
        This means 2804 full periods have passed since the epoch (January 1, 1970). So since ethereum started, 2804 full periods have passed. there are 2804 7 day periods that have passed since the epoch

        + 2:

        This adds 2 to the number of full periods. So:
        2804 + 2 = 2806
        This means we’re looking at the period that is two periods ahead of the current one. You will see why below

        * periodDuration:

        This multiplies the result by periodDuration to convert it back into a timestamp:
        2806 * 604800 = 1696723200
        This gives us the start time of the period that is two periods ahead.

        Example
        Let’s say:

        Today is October 1, 2023, 00:00:00 UTC.

        Each period is 7 days long (periodDuration = 604800 seconds).

        Step 1: Calculate the number of full periods that have passed.
        
        currentTime = 1696118400 (October 1, 2023, 00:00:00 UTC)
        periodDuration = 604800 (7 days in seconds)

        Number of full periods = currentTime / periodDuration
                            = 1696118400 / 604800
                            = 2804
        Step 2: Add 2 to skip the current and next period.
       
        2804 + 2 = 2806
        Step 3: Multiply by periodDuration to get the start time of the future period.
        2806 * 604800 = 1696723200
        
        Result:
        1696723200 corresponds to October 15, 2023, 00:00:00 UTC.

        This is how we know that 2 weeks have passed from the current time. So the new period is created 2 weeks from the current time. So we know now that when nextPeriod = ((currentTime / _periodDuration) * _periodDuration) + _periodDuration is called, all we are doing is setting up a period 2 weeks ahead of now. 

       your next question is probably wtf does the weight do here because the max emissions are determined in an emissions variable in the periodState.emission and this variable is what is checked to make sure that rewards sent from the gauge controller do not exceed a particular amount. so the value set as the weight in this function, what is the significance of it ??

       if your guess was that this was another one of those useless things that this protocol implemented that does absolutely nothing, you would be correct. the weight here does absolutely nothing. where the weight of a gauge becomes relevant is in gaugecontroller.sol where a gauge is added with gaugecontroller::addgauge where the weight of the gauge is calculated and then a user can vote which either increases or decreases the weight of the gauge and the rewards given to the gauge are based on the weights of the gauges. so the weight set here is absolutely useless.

    */

    /**
     * @notice Gets time-weighted average weight
     * @return Current average weight
     */
    function getTimeWeightedWeight() public view override returns (uint256) {
        return periodState.votingPeriod.calculateAverage(block.timestamp);
    }

    /**
     * @notice Gets start of current period
     * @return Current period start timestamp
     */
    function getCurrentPeriodStart() public view returns (uint256) {
        return periodState.periodStartTime;
    }

    /**
     * @notice Updates boost calculation parameters
     * @param _maxBoost Maximum boost multiplier
     * @param _minBoost Minimum boost multiplier
     * @param _boostWindow Time window for boost
     * @dev Only callable by controller
     */
    function setBoostParameters(
        uint256 _maxBoost,
        uint256 _minBoost,
        uint256 _boostWindow
    ) external onlyController {
        boostState.maxBoost = _maxBoost;
        boostState.minBoost = _minBoost;
        boostState.boostWindow = _boostWindow;
    }

    // View functions

    /**
     * @notice Gets latest applicable reward time
     * @return Latest of current time or period end
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return
            block.timestamp < periodFinish() ? block.timestamp : periodFinish();
    } //c block.timestamp < periodFinish will almost always be the case because as seen below, the period finish is the last time rewards were updated + the period duration. lastupdatetime is updated in _updateReward which is called in pretty much every major function in this contract. so think of it like this. lasttimerewardapplicable will always be the timestamp of the lasttime any major function in this contract was called.

    /**
     * @notice Gets end time of current period
     * @return Period end timestamp
     */
    function periodFinish() public view returns (uint256) {
        return lastUpdateTime + getPeriodDuration();
    } //q isnt this strange, the period finish takes the last time rewards were updated and adds the period duration to it. this isnt actually when the period finishes. the period finishes when the period start time + period duration is reached. so what are the implications of this ??

    /**
     * @notice Calculates current reward per token
     * @return Current reward per token value
     */
    function getRewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) *
                rewardRate *
                1e18) / totalSupply());
    }

    /**
     * @notice Calculates earned rewards for account
     * @param account Address to calculate earnings for
     * @return Amount of rewards earned
     */
    function earned(address account) public view returns (uint256) {
        return
            ((getUserWeight(account) *
                (getRewardPerToken() -
                    userStates[account].rewardPerTokenPaid)) / 1e18) +
            userStates[account].rewards;
    } //c so this is multiplying the 'user's' weight by the difference between the current reward per token and the last reward per token stored for the user. userStates[account].rewardPerTokenPaid is updated in _updatereward after this function is called to be whatever the latest value of getRewardPerToken() is. so the idea is to get the difference between the rewards this is then divided by 1e18 to allow for proper precision. this is then added to the rewards that the user has already been paid.

    /**
     * @notice Gets user's current weight including boost
     * @param account Address to get weight for
     * @return User's current weight
     */
    function getUserWeight(
        address account
    ) public view virtual returns (uint256) {
        uint256 baseWeight = _getBaseWeight(account);
        return _applyBoost(account, baseWeight);
    }

    /**
     * @notice Creates checkpoint for reward calculations
     */
    function checkpoint() external updateReward(msg.sender) {
        emit Checkpoint(msg.sender, block.timestamp);
    }

    /**
     * @notice Gets duration of reward period
     * @return Period duration in seconds
     */
    function getPeriodDuration() public view virtual returns (uint256) {
        return 7 days; // Default period duration, can be overridden by child contracts
    }

    /**
     * @notice Gets total weight of gauge
     * @return Total gauge weight
     */
    function getTotalWeight() external view virtual override returns (uint256) {
        return totalSupply();
    }
}
