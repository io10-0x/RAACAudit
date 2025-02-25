// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../math/TimeWeightedAverage.sol";

/**
 * @title Boost Calculator Library
 * @author RAAC Protocol Team
 * @notice Library for calculating and managing boost multipliers for reward distribution
 * @dev Implements Curve-style boost calculations with time-weighted averages
 * Key features:
 * - Dynamic boost calculation based on veToken holdings
 * - Time-weighted average tracking
 * - Configurable boost parameters via struct
 * - Balance updates with historical tracking
 */
library BoostCalculator {
    using TimeWeightedAverage for TimeWeightedAverage.Period;
    using TimeWeightedAverage for TimeWeightedAverage.Period[];

    struct BoostParameters {
        uint256 maxBoost;
        uint256 minBoost;
        uint256 boostWindow;
        uint256 totalWeight;
        uint256 totalVotingPower;
        uint256 votingPower;
    }
    /**
     * @notice Structure containing boost calculation state and configuration
     * @dev Maintains user periods, global state, and boost parameters
     */
    struct BoostState {
        mapping(address => TimeWeightedAverage.Period) userPeriods; // User-specific time periods
        TimeWeightedAverage.Period boostPeriod; // Global boost period
        uint256 maxBoost; // Maximum allowed boost (in basis points)
        uint256 minBoost; // Minimum allowed boost (in basis points)
        uint256 boostWindow; // Time window for boost calculations
        uint256 baseWeight; // Base weight for calculations
        uint256 votingPower; // Current voting power
        uint256 totalWeight; // Total weight in the system
        uint256 totalVotingPower; // Total voting power in the system
    }

    /**
     * @notice Emitted when a user's boost multiplier changes
     * @param user Address of the user whose boost changed
     * @param oldBoost Previous boost value
     * @param newBoost New boost value
     */
    event BoostUpdated(
        address indexed user,
        uint256 oldBoost,
        uint256 newBoost
    );

    /**
     * @notice Thrown when boost calculation parameters are invalid
     */
    error InvalidBoostParameters();

    /**
     * @notice Thrown when boost window is set to zero
     */
    error InvalidBoostWindow();

    /**
     * @notice Thrown when boost bounds are incorrectly configured
     */
    error InvalidBoostBounds();

    /**
     * @notice Calculates boost based on veToken ratio
     * @dev Uses voting power and total supply to determine boost multiplier
     * @param veBalance The user's veToken balance
     * @param totalVeSupply The total veToken supply
     * @param params The boost parameters containing configuration
     * @return boost The calculated boost value (in basis points)
     */
    function calculateBoost(
        uint256 veBalance,
        uint256 totalVeSupply,
        BoostParameters memory params
    ) internal pure returns (uint256) {
        // Return base boost (1x = 10000 basis points) if no voting power
        if (totalVeSupply == 0) {
            return params.minBoost;
        }

        // Calculate voting power ratio with higher precision
        uint256 votingPowerRatio = (veBalance * 1e18) / totalVeSupply;
        // Calculate boost within min-max range
        uint256 boostRange = params.maxBoost - params.minBoost; //c if maxBoost is 25000 and minBoost is 1e18, how is this not going to be negative. this is a bug
        uint256 boost = params.minBoost +
            ((votingPowerRatio * boostRange) / 1e18); //c there is definitely precision loss going on here

        // Ensure boost is within bounds
        if (boost < params.minBoost) {
            return params.minBoost;
        } //c this situation would simply never happen based on this formula. if the voting power ratio is 0, the boost would be the minboost. if the voting power ratio is 1, the boost would be the maxboost. if the voting power ratio is 0.5, the boost would be the average of the minboost and maxboost.
        if (boost > params.maxBoost) {
            return params.maxBoost;
        }

        return boost;
    }

    /**
     * @notice Updates user's balance for boost calculation
     * @dev Creates or updates the user's time-weighted average period
     * @param state The boost state
     * @param user The user address
     * @param newBalance The new balance to record
     */
    function updateUserBalance(
        BoostState storage state,
        address user,
        uint256 newBalance
    ) internal {
        if (state.boostWindow == 0) revert InvalidBoostWindow();

        TimeWeightedAverage.Period storage userPeriod = state.userPeriods[user];

        if (userPeriod.startTime == 0) {
            TimeWeightedAverage.createPeriod(
                userPeriod,
                block.timestamp + 1,
                state.boostWindow,
                newBalance,
                1e18 // normalized weight
            );
        } else {
            userPeriod.updateValue(newBalance, block.timestamp);
        }
    }

    /**
     * @notice Updates the global boost period
     * @dev Initializes or updates the time-weighted average for global boost
     * @param state The boost state to update
     */
    function updateBoostPeriod(BoostState storage state) internal {
        //c so the idea of a boost is that there is a certain period where users can earn boosted rewards so this is what this boost does. Judging from the line below, there is a boostwindow available which indicates a time period where users can get boosted rewards and the boost window cannot be 0

        //c note that the natspec says that this function updates the global boost period. this means that this function takes ALL USERS into account in its boost calculations. this is different from the updateUserBalance function which only takes a single user into account
        if (state.boostWindow == 0) revert InvalidBoostWindow();
        if (state.maxBoost < state.minBoost) revert InvalidBoostBounds();

        uint256 currentTime = block.timestamp;
        uint256 periodStart = state.boostPeriod.startTime;
        //c so this boostPeriod is a struct in the Timeweightedaverage library and it has a start time and an end time. This period is used to store certain data which we are about to find out

        // If no period exists, create initial period starting from current block
        if (periodStart > 0) {
            // If current period has ended, create new period
            if (currentTime >= periodStart + state.boostWindow) {
                //c the period struct also contains an endtime variable so this if condition is saying that the endTime should ideally be the startTime + boost window. this is something i can check .if the start time + time window != end time at any point, we could have something nice here

                TimeWeightedAverage.createPeriod(
                    state.boostPeriod,
                    currentTime,
                    state
                        .boostWindow /*bug so the fact that boosted window is set as the duration in the createPeriod function, and the createperiod function contains the following check 
                        if (
                            self.startTime != 0 &&
                            startTime < self.startTime + self.totalDuration
                        ) {
                            revert PeriodNotElapsed();
                        }

                        and in timeweightedaverage::updateValue, the total duration is added to everytime it is calculated. let me use an example to explain:

                        so i create a period at t = 20 and boostwindow = 10. in createperiod, the endtime is 20 + 10 = 30. totalduration is now set to 10. so if another user locks tokens at t=25 and boostwindow = 10, the current time will be less than the periods endtime which means TimeWeightedAverage::updatevalue is going to be called . in that function, totalduration increases by 5 as that function calculates a duration variable which is current timestamp - lastupdatedtimestamp and as we know, lastupdatedtimestamp from createperiod is 20. so the duration there will be 5. this 5 is then added to the totalduration which is now 15.  

                        so now another user comes to lock tokens at t=32. periodstart is > 0 which passes the first if statement. currenttime which is now 32 is greater than the periodstart + boostwindow which is still 30 as you remember so this function assumes that the period has ended and attempts to create a new period. so timeweightedaverage::createperiod is called which triggers the if  statement in that function which is going to check if self.startTime which is 20 if you remember is not 0 which is is and is also going to check that current time which is 32 is less than self.startTime + self.totalduration which is 20 + 15 = 35. This is true so the function will revert when it shouldnt. so at this point, whoever is locking tokens at t=32 will revert for no reason 
                    */,
                    state.votingPower,
                    state.maxBoost
                );
                return;
            }
            // Update existing period
            state.boostPeriod.updateValue(state.votingPower, currentTime);
            return; //c so if the period has a start time but hasnt ended, we want to update the values in the period which is what this function does
        }

        // If no period exists, create initial period starting from current block
        TimeWeightedAverage.createPeriod(
            state.boostPeriod,
            currentTime,
            state.boostWindow,
            state.votingPower,
            state.maxBoost
        );
    }

    /**
     * @notice Calculates time-weighted boost for a given amount
     * @dev Applies boost multiplier to the input amount based on user's position
     * @param state The boost state
     * @param userBalance The user's veToken balance
     * @param totalSupply The total veToken supply
     * @param amount The amount to boost
     * @return boostBasisPoints The calculated boost multiplier in basis points
     * @return boostedAmount The calculated boosted amount
     */
    function calculateTimeWeightedBoost(
        BoostState storage state,
        uint256 userBalance,
        uint256 totalSupply,
        uint256 amount
    ) internal view returns (uint256 boostBasisPoints, uint256 boostedAmount) {
        if (totalSupply == 0 || amount == 0) {
            return (0, amount);
        }

        // Create parameters struct for calculation
        BoostParameters memory params = BoostParameters({
            maxBoost: state.maxBoost,
            minBoost: state.minBoost,
            boostWindow: state.boostWindow,
            totalWeight: state.totalWeight,
            totalVotingPower: state.totalVotingPower,
            votingPower: state.votingPower
        });

        // Get boost multiplier in basis points (e.g., 10000 = 1x, 25000 = 2.5x)
        boostBasisPoints = calculateBoost(userBalance, totalSupply, params);

        // Calculate boosted amount: amount * (boost / 10000)
        boostedAmount = (amount * boostBasisPoints) / 10000;

        return (boostBasisPoints, boostedAmount);
    }

    // Overloaded function for memory parameters (for testing)
    function calculateTimeWeightedBoost(
        BoostParameters memory params,
        uint256 userBalance,
        uint256 totalSupply,
        uint256 amount
    ) internal pure returns (uint256 boostBasisPoints, uint256 boostedAmount) {
        if (totalSupply == 0 || amount == 0) {
            return (0, amount);
        }

        // Get boost multiplier in basis points (e.g., 10000 = 1x, 25000 = 2.5x)
        boostBasisPoints = calculateBoost(userBalance, totalSupply, params);

        // Calculate boosted amount: amount * (boost / 10000)
        boostedAmount = (amount * boostBasisPoints) / 10000;

        return (boostBasisPoints, boostedAmount);
    }
}
