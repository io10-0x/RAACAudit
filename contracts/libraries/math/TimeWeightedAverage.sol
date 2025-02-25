// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Time-Weighted Average Library
 * @author RAAC Protocol Team
 * @notice Library for calculating time-weighted averages with support for weighted periods
 * @dev Provides functionality for tracking and calculating time-weighted averages of values
 * Key features:
 * - Period creation and management
 * - Time-weighted value tracking
 * - Support for weighted periods
 * - Multiple period calculations
 */

library TimeWeightedAverage {
    /**
     * @notice Structure representing a time period with associated value and weight
     * @dev Stores all necessary data for time-weighted calculations
     */
    struct Period {
        uint256 startTime; // Beginning timestamp of the period
        uint256 endTime; // End timestamp of the period
        uint256 lastUpdateTime; // Last timestamp the value was updated
        uint256 value; // Current value being tracked
        uint256 weightedSum; // Running sum of time-weighted values
        uint256 totalDuration; // Total duration of accumulated values
        uint256 weight; // Weight applied to period (scaled by 1e18)
    }

    /**
     * @notice Parameters for calculating averages across multiple periods
     * @dev Used when processing multiple time periods in batch
     */
    struct PeriodParams {
        uint256 startTime; // Start timestamp of period
        uint256 endTime; // End timestamp of period
        uint256 value; // Value for period
        uint256 weight; // Weight of period (scaled by 1e18)
    }

    /**
     * @notice Emitted when a new period is created
     * @param startTime Start timestamp of the period
     * @param duration Duration in seconds
     * @param initialValue Starting value
     */
    event PeriodCreated(
        uint256 startTime,
        uint256 duration,
        uint256 initialValue
    );

    /**
     * @notice Emitted when a period's value is updated
     * @param timestamp Time of update
     * @param oldValue Previous value
     * @param newValue New value
     */
    event ValueUpdated(uint256 timestamp, uint256 oldValue, uint256 newValue);

    /**
     * @notice Thrown when timestamp is outside valid range
     */
    error InvalidTime();

    /**
     * @notice Thrown when weight parameter is invalid
     */
    error InvalidWeight();

    /**
     * @notice Thrown when period duration is zero
     */
    error ZeroDuration();

    /**
     * @notice Thrown when start time is invalid
     */
    error InvalidStartTime();

    /**
     * @notice Thrown when value calculation overflows
     */
    error ValueOverflow();

    /**
     * @notice Thrown when weight is zero
     */
    error ZeroWeight();

    /**
     * @notice Thrown when period has not elapsed
     */
    error PeriodNotElapsed();

    /**
     * @notice Creates a new time-weighted average period
     * @dev Initializes a period with given parameters and validates inputs
     * @param self Storage reference to Period struct
     * @param startTime Start time of the period
     * @param duration Duration of the period
     * @param initialValue Initial value for the period
     * @param weight Weight to apply to the period (scaled by 1e18)
     */
    function createPeriod(
        Period storage self,
        uint256 startTime,
        uint256 duration,
        uint256 initialValue,
        uint256 weight
    ) internal {
        if (
            self.startTime != 0 &&
            startTime < self.startTime + self.totalDuration
        ) {
            revert PeriodNotElapsed();
        } //c this if is kinda weird because it checks if startTime < self.startTime + self.totalDuration and in the above natspec for totalDuration, it says it is the Total duration of accumulated values, what does this mean?? Surely you would just check if startTime < self.endTime ?? I can see below that self.totalDuration is updated as the duration passed to this function and the endTime is updated as startTime + duration, so this check is just checking if the new period starts before the end of the previous period but my earlier point still stands as they could just check the endTime

        if (duration == 0) revert ZeroDuration();
        if (weight == 0) revert ZeroWeight();

        self.startTime = startTime;
        self.endTime = startTime + duration;
        self.lastUpdateTime = startTime;
        self.value = initialValue;
        self.weightedSum = 0; //c as for this weighted sum and the value variable above this, i am not currently sure what they do but I will find out when i see how a period is updated which is probably in the function below. I will update here once i find out
        self.totalDuration = duration;
        self.weight = weight; //c i can see that the maxBoost is passed to this function when it is called in the boostCalculator::updateBoostPeriod so this assumes that the weight is the amount of rewards to be distributed throughout the period

        emit PeriodCreated(startTime, duration, initialValue);
    }

    /**
     * @notice Updates current value and accumulates time-weighted sums
     * @dev Calculates weighted sum based on elapsed time since last update
     * @param self Storage reference to Period struct
     * @param newValue New value to set
     * @param timestamp Time of update
     */
    function updateValue(
        Period storage self,
        uint256 newValue,
        uint256 timestamp
    ) internal {
        if (timestamp < self.startTime || timestamp > self.endTime) {
            revert InvalidTime();
        }

        unchecked {
            //c unchecked block here so if any of this math over/underflows here, there will be no error thrown so this is a good place to check for overflows
            uint256 duration = timestamp - self.lastUpdateTime;
            if (duration > 0) {
                uint256 timeWeightedValue = self.value * duration;
                /*c before we continue, you need to understand what this self.value variable actually does. In the createperiod function above, self.value is set to initialvalue and when createPeriod is called in the boostCalculator::updateBoostPeriod, the initial value is the voting power of the user. so remember what this period struct is supposed to do. it stores values of a current period where a certain boost is to be applied for all users who have locked their tokens. so when a user locks their tokens with veRAACToken::lock, veRAACToken::_updateBoostState is called in that function which calculates the user's current balance (adjusted bias) and then boostcalculator::_updateBoostPeriod is called and this function checks to see if a period is currently active and if it is, then self.value is updated to add the balance of the user who has deposited which is what this function is supposed to do. 
                
                 so any users who lock their tokens between a period's start and end times will be eligible to earn boosted rewards in that period and these rewards are the self.weight variable in the period struct which is set when the period is created with createperiod function above

                your next question is probably, why is the total balance(voting power) multiplied by the duration, this is where the whole idea of time weighted average comes in. So the main takeaway point is that whenever a user locks tokens , it is not only their current balance is taken into account but how long they have held that position for. this comes together to determine the weight of their vote. This is a theme you will see throughout these ve mechanics. 

                The best way to visualize this is with an example:

                Example Of how it is supposed to work:

                    Period is between 0 to 100 seconds.
                    Alice locks 10 tokens at 0s. This calls the createPeriod function and self.value is set to 10. Weighted sum is 0

                    First update happens at 10s as Bob locks 20 tokens at 10s. This calls the updateValue function and the following happens:
                    Duration = 10s.
                    Contribution = 10 * 10 = 100.
                    weightedSum = 100, totalDuration = 10.
                    

                    you are probably wondering how is the contribution is 100, shouldnt it be 20 * 10 = 200 ? No it wont because when Alice locked tokens, self.value was set to her lock value which was 10 so when Bob locks tokens, what is updated is actually Alices' lock value which is 10. Once this done, self.value is then changed to Bob's lock value + Alice's lock value which is 30. This is why the contribution is 100 which represents the total time weighted sum so far at the current block timestamp.

                    Second update at 70s as Jane locks 30 tokens at 70s. This calls the updateValue function and the following happens:

                    Duration = 60s.
                    Contribution = 30 * 60 = 1800.
                    weightedSum = 1900, totalDuration = 70.
                    self.value = 10 +20+30 = 60
                    self.lastUpdateTime = block.timestamp

                    The reason this makes sense is because this updatevalue as I said before is called when BoostCalculator::updateBoostPeriod is called in the natspec of that function, it says clearly that it updates the global boost multiplier for that period. So this function takes ALL USERS into account in its boost calculations. this is different from the updateUserBalance function which only takes a single user into account. This is why self.value is always updated to add the latest user's balance so that on the next run, the timeweighted sum includes all user's deposits.

                    */

                /* bug
                Example of what is actually happening in this function:

                    Period is between 0 to 100 seconds.
                    Alice locks 10 tokens at 0s. This calls the createPeriod function and self.value is set to 10. Weighted sum is 0

                    First update happens at 10s as Bob locks 20 tokens at 10s. This calls the updateValue function and the following happens:
                    Duration = 10s.
                    Contribution = 10 * 10 = 100.
                    weightedSum = 100
                    self.value = 20
                    
                     So as you can see, when Bob locks tokens, self.value is updated to Bob's lock value which is 20. This is where the bug is. As explained above, since this is the global boost, it is supposed to include every user's balance when updating self.value so instead of self.value = newValue, it should be self.value += newValue. This is because the self.value is supposed to be the sum of all users' balances who have locked tokens in that period. This is why the contribution is 100 which represents the total time weighted sum so far at the current block timestamp.


                     This does raise another question as to what happens if a user unlocks their tokens? Well a user shouldnt be able to unlock their tokens once they lock them until their duration is over and the minimum duration as seen from veRAACToken.sol is 1 year and the boost window is 7 days so it is not possible that a user can unlock when they are in a period as the min lock is 1 year

                   
                    Second update at 70s as Jane locks 30 tokens at 70s. This calls the updateValue function and the following happens:

                    Duration = 60s.
                    Contribution = 20 * 60 = 1200.
                    weightedSum = 1300

                This is very much a valid bug as I have explained here but for RAAC, this is going to end up being a low which i will report but later. This does seem like a high but in the bigger picture, let me explain why it is a low . this updatevalue is only called in the updateboostperiod function in the boost controller and all of this logic is only used in veRAACToken::_updateBoostState which updates the global boost state but if you do global searches for anywhere the total weighted sum which is where the bug in this function is, is used , it literally never used anywhere in relation to the periods created in the veRAACToken. In fact, the only relevance a period in veRAACToken is relevant are the periods created for specific users which are used for gauge voting which i will be covering in the gauge contracts like baseGuage.sol, RAACGuage.sol so go have a look at those. the global period created when any user locks RAAC which is what this function updates, it really has no impact as it doesnt do anything apart from update itself whenever a user locks or increases locks so unless there is a way this stops any of these functions from working , it will be a low but lets see.

                   
                */

                if (timeWeightedValue / duration != self.value)
                    revert ValueOverflow();
                self.weightedSum += timeWeightedValue;
                self.totalDuration += duration;
            }
        }

        self.value = newValue;
        self.lastUpdateTime = timestamp;
    }

    /**
     * @notice Calculates time-weighted average up to timestamp
     * @dev Includes current period if timestamp > lastUpdateTime
     * @param self Storage reference to Period struct
     * @param timestamp Timestamp to calculate average up to
     * @return Time-weighted average value
     */
    function calculateAverage(
        Period storage self,
        uint256 timestamp
    ) internal view returns (uint256) {
        if (timestamp <= self.startTime) return self.value;

        uint256 endTime = timestamp > self.endTime ? self.endTime : timestamp;
        uint256 totalWeightedSum = self.weightedSum;

        if (endTime > self.lastUpdateTime) {
            uint256 duration = endTime - self.lastUpdateTime;
            uint256 timeWeightedValue = self.value * duration;
            if (duration > 0 && timeWeightedValue / duration != self.value)
                revert ValueOverflow();
            totalWeightedSum += timeWeightedValue;
        }

        return totalWeightedSum / (endTime - self.startTime);
    }

    /**
     * @notice Gets current value without time-weighting
     * @param self Storage reference to Period struct
     * @return Current raw value
     */
    function getCurrentValue(
        Period storage self
    ) internal view returns (uint256) {
        return self.value;
    }

    /**
     * @notice Calculates average across multiple periods
     * @dev Handles sequential or overlapping periods with weights
     * @param periods Array of period parameters
     * @param timestamp Timestamp to calculate up to
     * @return weightedAverage Time-weighted average across periods
     */
    function calculateTimeWeightedAverage(
        PeriodParams[] memory periods,
        uint256 timestamp
    ) public pure returns (uint256 weightedAverage) {
        uint256 totalWeightedSum;
        uint256 totalDuration;
        // We will iterate through each period and calculate the time-weighted average
        for (uint256 i = 0; i < periods.length; i++) {
            if (timestamp <= periods[i].startTime) continue;

            uint256 endTime = timestamp > periods[i].endTime
                ? periods[i].endTime
                : timestamp;
            uint256 duration = endTime - periods[i].startTime;

            unchecked {
                // Calculate time-weighted value by multiplying value by duration
                // This represents the area under the curve for this period
                uint256 timeWeightedValue = periods[i].value * duration;
                if (timeWeightedValue / duration != periods[i].value)
                    revert ValueOverflow();
                totalWeightedSum += timeWeightedValue * periods[i].weight;
                totalDuration += duration;
            }
        }

        return
            totalDuration == 0 ? 0 : totalWeightedSum / (totalDuration * 1e18);
    }
}
