// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../../libraries/math/PercentageMath.sol";
import "../../libraries/math/WadRayMath.sol";

import "../../interfaces/core/tokens/IDebtToken.sol";
import "../../interfaces/core/tokens/IRToken.sol";

/**
 * @title ReserveLibrary
 * @notice Library for managing reserve operations in the RAAC lending protocol.
 * @dev Provides functions to update reserve interests, calculate rates, and handle deposits and withdrawals.
 */
library ReserveLibrary {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    // Constants
    uint256 internal constant SECONDS_PER_YEAR = 31536000;

    // Structs

    /**
     * @notice Struct to hold reserve data.
     * @dev All values are stored in RAY (27 decimal) precision.
     */
    struct ReserveData {
        address reserveRTokenAddress;
        address reserveAssetAddress;
        address reserveDebtTokenAddress;
        uint256 totalLiquidity;
        uint256 totalUsage;
        uint128 liquidityIndex;
        uint128 usageIndex;
        uint40 lastUpdateTimestamp;
        uint256 timeDelta; //c for testing purposes
        uint256 cumulatedInterest; //c for testing purposes
    }

    /**
     * @notice Struct to hold reserve rate parameters.
     * @dev All values are stored in RAY (27 decimal) precision.
     */
    struct ReserveRateData {
        uint256 currentLiquidityRate;
        uint256 currentUsageRate;
        uint256 primeRate;
        uint256 baseRate;
        uint256 optimalRate;
        uint256 maxRate;
        uint256 optimalUtilizationRate;
        uint256 protocolFeeRate;
    }

    // Events

    /**
     * @notice Emitted when a deposit operation occurs.
     * @param user The address of the user making the deposit.
     * @param amount The amount deposited.
     * @param liquidityMinted The amount of liquidity tokens minted.
     */
    event Deposit(
        address indexed user,
        uint256 amount,
        uint256 liquidityMinted
    );

    /**
     * @notice Emitted when a withdraw operation occurs.
     * @param user The address of the user withdrawing.
     * @param amount The amount withdrawn.
     * @param liquidityBurned The amount of liquidity tokens burned.
     */
    event Withdraw(
        address indexed user,
        uint256 amount,
        uint256 liquidityBurned
    );

    /**
     * @notice Emitted when reserve interests are updated.
     * @param liquidityIndex The new liquidity index.
     * @param usageIndex The new usage index.
     */
    event ReserveInterestsUpdated(uint256 liquidityIndex, uint256 usageIndex);

    /**
     * @notice Emitted when interest rates are updated.
     * @param liquidityRate The new liquidity rate.
     * @param usageRate The new usage rate.
     */
    event InterestRatesUpdated(uint256 liquidityRate, uint256 usageRate);

    /**
     * @notice Emitted when the prime rate is updated.
     * @param oldPrimeRate The old prime rate.
     * @param newPrimeRate The new prime rate.
     */
    event PrimeRateUpdated(uint256 oldPrimeRate, uint256 newPrimeRate);

    // Custom Errors

    error TimeDeltaIsZero();
    error LiquidityIndexIsZero();
    error InvalidAmount();
    error PrimeRateMustBePositive();
    error PrimeRateChangeExceedsLimit();
    error InsufficientLiquidity();
    error InvalidInterestRateParameters();

    // Functions

    /**
     * @notice Updates the liquidity and usage indices of the reserve.
     * @dev Should be called before any operation that changes the state of the reserve.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     */
    function updateReserveInterests(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal {
        uint256 timeDelta = block.timestamp -
            uint256(reserve.lastUpdateTimestamp);
        if (timeDelta < 1) {
            return;
        }
        //c this stops the reserve rate from updating if it has just been updated. if 2 transactions are in the same block, then blocktimestamp is 0 so if I place my transaction in the same block as another transaction, the reserve rate will not update

        uint256 oldLiquidityIndex = reserve.liquidityIndex;
        if (oldLiquidityIndex < 1) revert LiquidityIndexIsZero();
        //c liquidity index should never go down. This is an invariant that should be maintained

        // Update liquidity index using linear interest
        //c i covered what the liquidity index is in the notes.md and also in the below function
        reserve.liquidityIndex = calculateLiquidityIndex(
            rateData.currentLiquidityRate, //c this is the interest rate that is being applied to the liquidity that users have deposited into the protocol. See notes.md for more info
            timeDelta,
            reserve.liquidityIndex,
            reserve
        );

        // Update usage index (debt index) using compounded interest
        //c notice how debt is compounded but liquidity is linear. Sneaky but legit
        reserve.usageIndex = calculateUsageIndex(
            rateData.currentUsageRate, //c this is the interest rate applied to debt that users have borrowed
            timeDelta,
            reserve.usageIndex
        );

        // Update the last update timestamp
        reserve.lastUpdateTimestamp = uint40(block.timestamp);
        reserve.timeDelta = timeDelta;

        emit ReserveInterestsUpdated(
            reserve.liquidityIndex,
            reserve.usageIndex
        );
    }

    /**
     * @notice Calculates the new liquidity index using linear interest.
     * @param rate The current liquidity rate (in RAY).
     * @param timeDelta The time since the last update (in seconds).
     * @param lastIndex The previous liquidity index.
     * @return The new liquidity index.
     */
    function calculateLinearInterest(
        uint256 rate,
        uint256 timeDelta,
        uint256 lastIndex,
        ReserveData storage reserve //c for testing purposes
    ) internal returns (uint256) {
        //c function should be pure but i changed for testing purposes
        uint256 cumulatedInterest = rate * timeDelta;
        //c so the interest rate(IN RAY) is multiplied by how much time has passed since the last update to get how much interest has been accumulated. so this value is the interest rate per second. Lets see an example to drill this home. so if interest rate is 20%, this will be 20% of 1e27 which is 5e25. So assume timedelta is is 100 seconds, then the interest accumulated will be 5e25 * 100 = 5e27. so total interest per second is 5e27 or 5% (5e27/1e27).
        reserve.cumulatedInterest = cumulatedInterest; //c for testing purposes
        cumulatedInterest = cumulatedInterest / SECONDS_PER_YEAR;
        //c then the interest rate per second is divided by the number of seconds in a year to get the interest rate per year. continuing from the above example, 5e27/31536000 = 1.58e21 or 0.00000158% annual interest rate

        return WadRayMath.RAY + cumulatedInterest;
        //c then the interest rate per year is added to 1e27 to make the cummulative interest have ray precision. continuing from the above example, 1e27 + 1.58e21 = 1.00000158e27 which is still 0.00000158% when you divide by 1e27 which is what happens in calculateliquidityindex function where rayMul is called. This will be the new cummulated interest from this update. To get the new liquidity index, this value will be multiplied by the old liquidity index. This is because the liquidity index is a cummulative value so it is the old value * the new interest rate.
    }

    function calculateLiquidityIndex(
        uint256 rate,
        uint256 timeDelta,
        uint256 lastIndex,
        ReserveData storage reserve //c for testing purposes
    ) internal returns (uint128) {
        //c this function should be pure but i changed for testing purposes
        uint256 cumulatedInterest = calculateLinearInterest(
            rate,
            timeDelta,
            lastIndex,
            reserve
        );

        return cumulatedInterest.rayMul(lastIndex).toUint128();
        //c so the cummulated interest is multiplied by the old liquidity index to get the new liquidity index. This is because The liquidity index stores a historical record of accrued interest, and by multiplying it with cumulatedInterest, we ensure correct compounding over time. The reason why we multiplied instead of adding is detailed in notes.md

        //q possible unsafe casting ??? not sure as rayMul always returns 27 decimals so I doubt that would be the case
    }

    /**
     * @notice Calculates the compounded interest over a period.
     * @param rate The usage rate (in RAY).
     * @param timeDelta The time since the last update (in seconds).
     * @return The interest factor (in RAY).
     */
    function calculateCompoundedInterest(
        uint256 rate,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        if (timeDelta < 1) {
            return WadRayMath.RAY;
        } //q this check isnt made in calculatelinearinterest which is interesting. need to look at this as this means this function or calculatelinearinterest might be called in another function where timedelta can be 0. If so, we can get  a divide by 0 error. NEED TO EXPLORE THIS.
        uint256 ratePerSecond = rate.rayDiv(SECONDS_PER_YEAR);

        uint256 exponent = ratePerSecond.rayMul(timeDelta);
        //c if you are wondering why the rate per second is calculated differently here than in calculatelinearinteerest function, it does look strange but it works. see reservelibrarymock::ratepersecondcomparison notes where i compared the cumulated interest from both functions and they are the same. The reasons are explained there so have a look there.

        // Will use a taylor series expansion (7 terms)
        //c notes on taylor expansion are in notes.md
        return WadRayMath.rayExp(exponent);
    }

    function calculateUsageIndex(
        uint256 rate,
        uint256 timeDelta,
        uint256 lastIndex
    ) internal pure returns (uint128) {
        uint256 interestFactor = calculateCompoundedInterest(rate, timeDelta);
        return lastIndex.rayMul(interestFactor).toUint128();
    }

    /**
     * @notice Updates the interest rates and liquidity based on the latest reserve state.
     * @dev Should be called after any operation that changes the liquidity or debt of the reserve.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @param liquidityAdded The amount of liquidity added (in underlying asset units).
     * @param liquidityTaken The amount of liquidity taken (in underlying asset units).
     */
    function updateInterestRatesAndLiquidity(
        ReserveData storage reserve,
        ReserveRateData storage rateData,
        uint256 liquidityAdded,
        uint256 liquidityTaken
    ) internal {
        // Update total liquidity
        if (liquidityAdded > 0) {
            reserve.totalLiquidity =
                reserve.totalLiquidity +
                liquidityAdded.toUint128();
        }
        if (liquidityTaken > 0) {
            if (reserve.totalLiquidity < liquidityTaken)
                revert InsufficientLiquidity();
            reserve.totalLiquidity =
                reserve.totalLiquidity -
                liquidityTaken.toUint128();
        }

        uint256 totalLiquidity = reserve.totalLiquidity;
        uint256 totalDebt = reserve.totalUsage;

        uint256 computedDebt = getNormalizedDebt(reserve, rateData);
        uint256 computedLiquidity = getNormalizedIncome(reserve, rateData);
        //bug there are 3 more lows here as none of these variables are used so why are they declared ???

        // Calculate utilization rate
        uint256 utilizationRate = calculateUtilizationRate(
            reserve.totalLiquidity,
            reserve.totalUsage
        ); //c if you look in LendingPool::deposit or borrow, you will see that the values passed as totalLiquidity and totalUsage are actually the normalized liquidity and normalized debt. I spoke about these in the notes.md and if you read those, it should tell you why it is preferred to use the normalized utilization rate here instead of the actual utilization rate

        // Update current usage rate (borrow rate)
        rateData.currentUsageRate = calculateBorrowRate(
            rateData.primeRate,
            rateData.baseRate,
            rateData.optimalRate,
            rateData.maxRate,
            rateData.optimalUtilizationRate,
            utilizationRate
        );

        // Update current liquidity rate
        rateData.currentLiquidityRate = calculateLiquidityRate(
            utilizationRate,
            rateData.currentUsageRate,
            rateData.protocolFeeRate,
            totalDebt
        );

        // Update the reserve interests
        updateReserveInterests(reserve, rateData);

        emit InterestRatesUpdated(
            rateData.currentLiquidityRate,
            rateData.currentUsageRate
        );
    }

    /**
     * @notice Calculates the liquidity rate based on utilization and usage rate.
     * @param utilizationRate The current utilization rate (in RAY).
     * @param usageRate The current usage rate (in RAY).
     * @param protocolFeeRate The protocol fee rate (in RAY).
     * @return The liquidity rate (in RAY).
     */
    function calculateLiquidityRate(
        uint256 utilizationRate,
        uint256 usageRate,
        uint256 protocolFeeRate,
        uint256 totalDebt
    ) internal pure returns (uint256) {
        if (totalDebt < 1) {
            return 0;
        }

        uint256 grossLiquidityRate = utilizationRate.rayMul(usageRate);
        uint256 protocolFeeAmount = grossLiquidityRate.rayMul(protocolFeeRate);
        uint256 netLiquidityRate = grossLiquidityRate - protocolFeeAmount; //c no overflow here I have checked. SEE "deposit function doesnt update liquidity rate iteration 2" test in LendingPool.test.js

        return netLiquidityRate;
    }

    /**
     * @notice Calculates the borrow rate based on utilization, adjusting for prime rate within the maxRate and baseRate window.
     * @param primeRate The prime rate of the reserve (in RAY).
     * @param baseRate The base rate (in RAY).
     * @param optimalRate The optimal rate (in RAY).
     * @param maxRate The maximum rate (in RAY).
     * @param optimalUtilizationRate The optimal utilization rate (in RAY).
     * @param utilizationRate The current utilization rate (in RAY).
     * @return The calculated borrow rate (in RAY).
     */
    function calculateBorrowRate(
        uint256 primeRate,
        uint256 baseRate,
        uint256 optimalRate,
        uint256 maxRate,
        uint256 optimalUtilizationRate,
        uint256 utilizationRate
    ) internal pure returns (uint256) {
        /*c so this function is based around 3 things. first thing you have to note is that the borrow rate is based around 3 things. the prime rate which is a target borrow rate that RAAC set. the base rate is lowest borrow rate that RAAC will accept and the max rate is the maximum borrow rate. This function is what determines the usage rate we use for the usage index.

        */

        if (
            primeRate <= baseRate ||
            primeRate >= maxRate ||
            optimalRate <= baseRate ||
            optimalRate >= maxRate
        ) {
            revert InvalidInterestRateParameters();
        }

        uint256 rate;
        if (utilizationRate <= optimalUtilizationRate) {
            uint256 rateSlope = primeRate - baseRate;
            //c the idea of this rate slope is that whenever utilization rate is lower than optimal , they want the borrow rate to be close to the base rate. Think about the slope like this. The gap between the base rate and the prime rate is not going to be that much but the gap between the prime rate and the max rate is going to be significantly more. So when utilization is low, the idea is to encourage more people to borrow so they want to keep the borrow rate close to the base rate so this slope between prime rate and base rate is going to be small.
            uint256 rateIncrease = utilizationRate.rayMul(rateSlope).rayDiv(
                optimalUtilizationRate
            );
            //c you can think of this rate increase like this utilization rate/optimal utilization rate * rate slope. so this represents the proportion of the rate slope that should be applied based on how much of the "optimal utilization" has been reached. NOTE THAT THIS IS DIFFERENT TO CALCULATING BY HOW MUCH THE RATE HAS BEEN UNDER/OVERUTILIZED. THERE IS A REASON IT ISNT CALCULATED LIKE THAT. EXPLAIN THIS. so if the utilization rate is 50% of the optimal utilization rate, then the rate increase will be 50% of the rate slope. if the utilization rate is 20% of the optimal utilization rate, then the rate increase will be 20% of the rate slope. this means the more underutilized the reserve is, the lower the borrow rate will be which is expected because we want to incentivize borrowing when the reserve is underutilized
            rate = baseRate + rateIncrease;
            //c finally, we want to add the rate increase to the base rate to get the final borrow rate when the utilization rate is under the optimal utilization rate
        } else {
            uint256 excessUtilization = utilizationRate -
                optimalUtilizationRate;
            //c same idea here, if the utilization rate is over the optimal utilization rate, then we want to increase the borrow rate. we will now be dealing with the gap between the prime rate and the max rate which is a much steeper slope than the rate slope between the prime rate and the base rate. This is because we want to discourage borrowing when the reserve is overutilized. you can even see this in the LendingPool constructor where these values are set
            uint256 maxExcessUtilization = WadRayMath.RAY -
                optimalUtilizationRate;
            uint256 rateSlope = maxRate - primeRate;
            uint256 rateIncrease = excessUtilization.rayMul(rateSlope).rayDiv(
                maxExcessUtilization
            );
            /*c The fact that excess utilisation rate is compared to max utilisation rate - optimal utilisation rate is because remember the idea is that when utilisation rate is over the optimal amount , we want the borrow rate to grow a lot to deter more borrows and encourage people to pay back their loans . 
            Breaking It Down:

            1. Below Optimal Utilisation (U < U_optimal):
            We compare U / U_optimal to see how much of the target utilisation has been used. This helps in setting a controlled, gradual increase in the borrow rate.

            2. Above Optimal Utilisation (U > U_optimal):

            We need a different approach because we are now in an undesirable zone where borrowing should be strongly discouraged. Here, we define Excess Utilisation as:

            U_{excess} = U - U_{optimal}

            Instead of comparing this directly to the max utilisation rate, we compare it to the remaining range between optimal and max:

            U_{excess}/ (U_{max} - U_{optimal})
            This fraction tells us how much of the remaining capacity has been exceeded.

            Why Not Compare Excess Directly to Max Utilisation Rate?
            The prime rate (linked to optimal utilisation) serves as a reference for the interest rate model.The remaining capacity beyond the optimal level is what determines how steeply the interest rate should rise. If we compared directly to U_max, we would be treating the excess as a fraction of the total capacity rather than focusing on the critical zone beyond optimal.
            Instead, we focus on how much of the danger zone (U_max - U_optimal) has been consumed, which better reflects how aggressive the borrow rate should increase.

            The Rate Slope Adjustment:
            When U < U_optimal, the slope of the rate increase is determined by subtracting the prime rate from the base rate. When U > U_optimal, we subtract U_max rate from the prime rate, ensuring that the interest rate increases sharply in proportion to how much we’ve exceeded the safe threshold. */

            rate = primeRate + rateIncrease;
        }
        return rate;
    }

    /**
     * @notice Calculates the utilization rate of the reserve.
     * @param totalLiquidity The total liquidity in the reserve (in underlying asset units).
     * @param totalDebt The total debt in the reserve (in underlying asset units).
     * @return The utilization rate (in RAY).
     */
    function calculateUtilizationRate(
        uint256 totalLiquidity,
        uint256 totalDebt
    ) internal pure returns (uint256) {
        //c should be internal but I changed for testing purposes
        if (totalLiquidity < 1) {
            return WadRayMath.RAY; // 100% utilization if no liquidity
            //c this says that if there is no liquidity, then the utilization rate is 100%. This is because the utilization rate is how much of the total liquidity is being borrowed. If there is no liquidity, then all of it is being borrowed so the utilization rate is 100%. This is a good check to have as it is a good way to check if the total liquidity is being updated correctly
            //c this assumes that if there is no liquidity, then there can be no debt, need to confirm this is true

            //c so if there is no liquidity, we dont want people to borrow so we set utilization rate to the max so the borrow rate will be max and discourage borrowing which makes sense
        }
        uint256 utilizationRate = totalDebt
            .rayDiv(totalLiquidity + totalDebt)
            .toUint128();
        return utilizationRate; //c the utilization rate is simply how much of the total liquidity is being borrowed.

        //c this formula is correct. the correct utilization rate formula is Utilization Rate= Total Borrowed/Total Available Liquidity+Total Borrowed. note that totalliquidity actually represents totalavailableliquidity as whenever a user borrows, the total liquidity is updated to reflect the amount borrowed by calling ReserveLibrary.updateInterestRatesAndLiquidity. This is why the formula is correct
    }

    /**
     * @notice Handles deposit operation into the reserve.
     * @dev Transfers the underlying asset from the depositor to the reserve, and mints RTokens to the depositor.
     *      This function assumes interactions with ERC20 before updating the reserve state (you send before we update how much you sent).
     *      A untrusted ERC20's modified mint function calling back into this library will cause incorrect reserve state updates.
     *      Implementing contracts need to ensure reentrancy guards are in place when interacting with this library.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @param amount The amount to deposit.
     * @param depositor The address of the depositor.
     * @return amountMinted The amount of RTokens minted.
     */
    function deposit(
        ReserveData storage reserve,
        ReserveRateData storage rateData,
        uint256 amount,
        address depositor
    ) internal returns (uint256 amountMinted) {
        if (amount < 1) revert InvalidAmount();

        // Update reserve interests
        updateReserveInterests(reserve, rateData);

        // Transfer asset from caller to the RToken contract
        IERC20(reserve.reserveAssetAddress).safeTransferFrom(
            msg.sender, // from
            reserve.reserveRTokenAddress, // to
            amount // amount
        );

        // Mint RToken to the depositor (scaling handled inside RToken)
        (
            bool isFirstMint,
            uint256 amountScaled,
            uint256 newTotalSupply,
            uint256 amountUnderlying
        ) = IRToken(reserve.reserveRTokenAddress).mint(
                address(this), // caller
                depositor, // onBehalfOf
                amount, // amount
                reserve.liquidityIndex // index
            );

        amountMinted = amountScaled;

        // Update the total liquidity and interest rates
        updateInterestRatesAndLiquidity(reserve, rateData, amount, 0);

        emit Deposit(depositor, amount, amountMinted);

        return amountMinted;
    }

    /**
     * @notice Handles withdrawal operation from the reserve.
     * @dev Burns RTokens from the user and transfers the underlying asset.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @param amount The amount to withdraw.
     * @param recipient The address receiving the underlying asset.
     * @return amountWithdrawn The amount withdrawn.
     * @return amountScaled The scaled amount of RTokens burned.
     * @return amountUnderlying The amount of underlying asset transferred.
     */
    function withdraw(
        ReserveData storage reserve,
        ReserveRateData storage rateData,
        uint256 amount,
        address recipient
    )
        internal
        returns (
            uint256 amountWithdrawn,
            uint256 amountScaled,
            uint256 amountUnderlying
        )
    {
        if (amount < 1) revert InvalidAmount();

        // Update the reserve interests
        updateReserveInterests(reserve, rateData);

        // Burn RToken from the recipient - will send underlying asset to the recipient
        (
            uint256 burnedScaledAmount,
            uint256 newTotalSupply,
            uint256 amountUnderlying
        ) = IRToken(reserve.reserveRTokenAddress).burn(
                recipient, // from
                recipient, // receiverOfUnderlying
                amount, // amount
                reserve.liquidityIndex // index
            );
        amountWithdrawn = burnedScaledAmount;

        // Update the total liquidity and interest rates
        updateInterestRatesAndLiquidity(reserve, rateData, 0, amountUnderlying);

        emit Withdraw(recipient, amountUnderlying, burnedScaledAmount);

        return (amountUnderlying, burnedScaledAmount, amountUnderlying);
    }

    /**
     * @notice Sets a new prime rate for the reserve.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @param newPrimeRate The new prime rate (in RAY).
     */
    function setPrimeRate(
        ReserveData storage reserve,
        ReserveRateData storage rateData,
        uint256 newPrimeRate
    ) internal {
        if (newPrimeRate < 1) revert PrimeRateMustBePositive();

        uint256 oldPrimeRate = rateData.primeRate;

        if (oldPrimeRate > 0) {
            uint256 maxChange = oldPrimeRate.percentMul(500); // Max 5% change
            uint256 diff = newPrimeRate > oldPrimeRate
                ? newPrimeRate - oldPrimeRate
                : oldPrimeRate - newPrimeRate;
            if (diff > maxChange) revert PrimeRateChangeExceedsLimit();
        }

        rateData.primeRate = newPrimeRate;
        updateInterestRatesAndLiquidity(reserve, rateData, 0, 0);

        emit PrimeRateUpdated(oldPrimeRate, newPrimeRate);
    }

    /**
     * @notice Updates the reserve state by updating the reserve interests.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     */
    function updateReserveState(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal {
        updateReserveInterests(reserve, rateData);
    }

    /**
     * @notice Gets the current borrow rate of the reserve.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @return The current borrow rate (in RAY).
     */
    function getBorrowRate(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal view returns (uint256) {
        uint256 totalDebt = getNormalizedDebt(reserve, rateData);
        //bug if timedelta > 1, total debt returns the updated usage index which isnt what we want at all. i want to prove this but there is nowhere in the codebase where this function is ever called so it is a low but it is worth pointing out why tf this is here.
        uint256 utilizationRate = calculateUtilizationRate(
            reserve.totalLiquidity,
            totalDebt
        );
        return
            calculateBorrowRate(
                rateData.primeRate,
                rateData.baseRate,
                rateData.optimalRate,
                rateData.maxRate,
                rateData.optimalUtilizationRate,
                utilizationRate
            );
    }

    /**
     * @notice Gets the current liquidity rate of the reserve.
     * @param reserve The reserve data.
     * @param rateData The reserve rate parameters.
     * @return The current liquidity rate (in RAY).
     */
    function getLiquidityRate(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal view returns (uint256) {
        uint256 totalDebt = getNormalizedDebt(reserve, rateData);
        //bug if timedelta > 1, total debt returns the updated usage index which isnt what we want at all. i want to prove this but there is nowhere in the codebase where this function is used so it is a low but it is worth pointing out why tf this is here.
        uint256 utilizationRate = calculateUtilizationRate(
            reserve.totalLiquidity,
            totalDebt
        );
        return
            calculateLiquidityRate(
                utilizationRate,
                rateData.currentUsageRate,
                rateData.protocolFeeRate,
                totalDebt
            );
        //c need to look at how the protocol implements this formula in this function
    }

    /**
     * @notice Gets the normalized income of the reserve.
     * @param reserve The reserve data.
     * @return The normalized income (in RAY).
     */
    function getNormalizedIncome(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal returns (uint256) {
        //c function should be view but i changed for testing purposes
        uint256 timeDelta = block.timestamp -
            uint256(reserve.lastUpdateTimestamp);
        if (timeDelta < 1) {
            return reserve.liquidityIndex;
        }

        return
            calculateLinearInterest(
                rateData.currentLiquidityRate,
                timeDelta,
                reserve.liquidityIndex,
                reserve
            ).rayMul(reserve.liquidityIndex);
    }

    /**
     * @notice Gets the normalized debt of the reserve.
     * @param reserve The reserve data.
     * @return The normalized debt (in underlying asset units).
     */
    function getNormalizedDebt(
        ReserveData storage reserve,
        ReserveRateData storage rateData
    ) internal view returns (uint256) {
        uint256 timeDelta = block.timestamp -
            uint256(reserve.lastUpdateTimestamp);
        if (timeDelta < 1) {
            return reserve.totalUsage;
        }
        //c total usage is like total debt. you can see this by global searching everytime this was used and you will see that it is used to reset the total debt of the protocol by always setting it to the total supply of the debt token everytime tokens are minted/burned. so this if condition is saying that if the timedelta is less than 1, it means that the debt value hasnt changed so we can simply return the total debt value which is reserve.totalUsage.

        //bug normalized debt in this context represents the usage index of the reserve just like the getnormaliseddebt function in lendingpool.sol. As you can see, even with the getnormalisedincome function about this, if timedelta <1, it returns the liquidity index so in this case, if timedelta < 1, it should return the usageIndex

        //c this function is used in the getborrowrate function above and that getborrowrate function is used in an updateInterestRatesAndLiquidity function which is also in this contract. the updateInterestRatesAndLiquidity function is called in lendingpool::borrow and probably a bunch of other places which i will find out. this means that there can be a state where getnormalized debt can be different values for the protocol. need to look into this which can lead to all sorts of issues. Need to prove this bug.

        return
            calculateCompoundedInterest(rateData.currentUsageRate, timeDelta)
                .rayMul(reserve.usageIndex);
    }
}
