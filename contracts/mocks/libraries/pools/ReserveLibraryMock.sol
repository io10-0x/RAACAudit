// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../../libraries/pools/ReserveLibrary.sol";
import "../../../libraries/math/PercentageMath.sol";
import "../../../libraries/math/WadRayMath.sol";

contract ReserveLibraryMock is ReentrancyGuard {
    using ReserveLibrary for ReserveLibrary.ReserveData;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    ReserveLibrary.ReserveData internal reserveData;
    ReserveLibrary.ReserveRateData internal rateData;
    uint256 public exponent;
    uint256 public exponent1;
    uint256 public interestFactor;
    uint256 public interestFactor1;

    constructor() {
        // Initialize indices
        reserveData.liquidityIndex = uint128(WadRayMath.RAY);
        reserveData.usageIndex = uint128(WadRayMath.RAY);
        reserveData.lastUpdateTimestamp = uint40(block.timestamp);

        // Set interest rate parameters
        rateData.baseRate = WadRayMath.RAY / 20; // 5%
        rateData.primeRate = WadRayMath.RAY / 10; // 10%
        rateData.optimalRate = (WadRayMath.RAY * 15) / 100; // 15%
        rateData.maxRate = WadRayMath.RAY; // 100%
        rateData.optimalUtilizationRate = WadRayMath.RAY / 2; // 50%
        rateData.protocolFeeRate = WadRayMath.RAY / 10; // 10%

        // Initialize current rates
        rateData.currentLiquidityRate = rateData.baseRate;
        rateData.currentUsageRate = rateData.baseRate;
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert ReserveLibrary.InvalidAmount();

        ReserveLibrary.updateInterestRatesAndLiquidity(
            reserveData,
            rateData,
            amount,
            0
        );

        return amount;
    }

    function withdraw(uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert ReserveLibrary.InvalidAmount();
        if (amount > reserveData.totalLiquidity)
            revert ReserveLibrary.InsufficientLiquidity();

        ReserveLibrary.updateInterestRatesAndLiquidity(
            reserveData,
            rateData,
            0,
            amount
        );

        return amount;
    }

    function setPrimeRate(uint256 newPrimeRate) external {
        if (newPrimeRate == 0) revert ReserveLibrary.PrimeRateMustBePositive();

        uint256 oldPrimeRate = rateData.primeRate;

        // For testing extremely high rates, adjust all rate parameters
        if (newPrimeRate >= rateData.maxRate) {
            // Maintain the required relationships:
            // baseRate < primeRate < maxRate && baseRate < optimalRate < maxRate
            rateData.baseRate = newPrimeRate / 2; // Set baseRate lower than prime
            rateData.optimalRate = (newPrimeRate * 3) / 4; // Set optimalRate between base and max
            rateData.maxRate = newPrimeRate * 2; // Set maxRate higher than prime

            // For testing purposes, directly set the prime rate
            rateData.primeRate = newPrimeRate;
            ReserveLibrary.updateInterestRatesAndLiquidity(
                reserveData,
                rateData,
                0,
                0
            );
            emit ReserveLibrary.PrimeRateUpdated(oldPrimeRate, newPrimeRate);
            return;
        }

        if (oldPrimeRate > 0) {
            uint256 maxChange = oldPrimeRate.percentMul(500); // Max 5% change
            uint256 diff = newPrimeRate > oldPrimeRate
                ? newPrimeRate - oldPrimeRate
                : oldPrimeRate - newPrimeRate;

            if (diff > maxChange) {
                // For testing purposes, directly set the rate
                rateData.primeRate = newPrimeRate;
                ReserveLibrary.updateInterestRatesAndLiquidity(
                    reserveData,
                    rateData,
                    0,
                    0
                );
                emit ReserveLibrary.PrimeRateUpdated(
                    oldPrimeRate,
                    newPrimeRate
                );
                return;
            }
        }

        // Use normal library function for normal rate changes
        ReserveLibrary.setPrimeRate(reserveData, rateData, newPrimeRate);
    }

    function calculateUtilizationRate() external view returns (uint256) {
        if (reserveData.totalLiquidity == 0 && reserveData.totalUsage == 0) {
            return 0; // Return 0 when both liquidity and usage are 0
        }
        return
            ReserveLibrary.calculateUtilizationRate(
                reserveData.totalLiquidity,
                reserveData.totalUsage
            );
    }

    function getReserveData()
        external
        view
        returns (
            uint256 totalLiquidity,
            uint256 totalUsage,
            uint256 liquidityIndex,
            uint256 usageIndex,
            uint256 lastUpdateTimestamp
        )
    {
        return (
            reserveData.totalLiquidity,
            reserveData.totalUsage,
            reserveData.liquidityIndex,
            reserveData.usageIndex,
            reserveData.lastUpdateTimestamp
        );
    }

    function getRateData()
        external
        view
        returns (
            uint256 currentLiquidityRate,
            uint256 currentUsageRate,
            uint256 primeRate,
            uint256 baseRate,
            uint256 optimalRate,
            uint256 maxRate,
            uint256 optimalUtilizationRate,
            uint256 protocolFeeRate
        )
    {
        return (
            rateData.currentLiquidityRate,
            rateData.currentUsageRate,
            rateData.primeRate,
            rateData.baseRate,
            rateData.optimalRate,
            rateData.maxRate,
            rateData.optimalUtilizationRate,
            rateData.protocolFeeRate
        );
    }

    // Helper function to simulate time passing (for testing)
    function setLastUpdateTimestamp(uint40 timestamp) external {
        reserveData.lastUpdateTimestamp = timestamp;
    }

    // Helper function to set all rate parameters at once (for testing)
    function setRateParameters(
        uint256 baseRate_,
        uint256 primeRate_,
        uint256 optimalRate_,
        uint256 maxRate_,
        uint256 optimalUtilizationRate_
    ) external {
        rateData.baseRate = baseRate_;
        rateData.primeRate = primeRate_;
        rateData.optimalRate = optimalRate_;
        rateData.maxRate = maxRate_;
        rateData.optimalUtilizationRate = optimalUtilizationRate_;
    }

    function calculateCompoundedInterestraydiv(
        uint256 rate,
        uint256 timeDelta
    ) external returns (uint256, uint256) {
        if (timeDelta < 1) {
            return (WadRayMath.RAY, 0);
        }

        uint256 ratePerSecond = rate.rayDiv(ReserveLibrary.SECONDS_PER_YEAR);
        exponent = ratePerSecond.rayMul(timeDelta);

        // Taylor series expansion for e^x
        interestFactor =
            WadRayMath.RAY +
            exponent +
            (exponent.rayMul(exponent)) /
            2 +
            (exponent.rayMul(exponent).rayMul(exponent)) /
            6 +
            (exponent.rayMul(exponent).rayMul(exponent).rayMul(exponent)) /
            24 +
            (
                exponent
                    .rayMul(exponent)
                    .rayMul(exponent)
                    .rayMul(exponent)
                    .rayMul(exponent)
            ) /
            120;

        return (exponent, interestFactor);
    }

    function ratepersecond(
        uint256 rate
    ) external pure returns (uint256 compounded, uint256 linear) {
        uint256 compounded = rate.rayDiv(ReserveLibrary.SECONDS_PER_YEAR);
        uint256 linear = rate / ReserveLibrary.SECONDS_PER_YEAR;
        return (compounded, linear);
    }

    function ratepersecondcomparison(
        uint256 rate,
        uint256 timeDelta
    )
        external
        pure
        returns (uint256 cumulatedInterest, uint256 cumulatedInterest2)
    {
        uint256 cumulatedInterestcalc = rate * timeDelta;
        cumulatedInterest =
            cumulatedInterestcalc /
            ReserveLibrary.SECONDS_PER_YEAR;
        uint256 ratePerSecond = rate.rayDiv(ReserveLibrary.SECONDS_PER_YEAR);
        cumulatedInterest2 = ratePerSecond.rayMul(timeDelta);
        return (cumulatedInterest, cumulatedInterest2);

        /*c let me explain why i designed this function. in reservelibrary::calculatelinearinterest, the cummulated interest is pretty much the rate per second and this rate per second is added to 1e27 to get the linear interest. It is linear because we dont consider previous interest rates from previous periods which is why we add it to 1e27 everytime. in the cummulated interest calculation, notice how the multiplication by time delta and then division by seconds per year is done without using ray precision.

        However, in the calculateCompoundedInterestraydiv function, the rate per second is the exponent variable and it is calculated using ray precision. the ratepersecond is first derived and we know that the rate per second is the rate divided by seconds per year. this is done using ray precision which is weird because timedelta is not in ray precision which raised a question mark because the result of this would mean that the rate per second would be scaled to have ray precision which will have a few extra zeros it may not require as rayDiv always multiplies the numerator by 1e27 to maintain precision as you know. 

        This seems like a problem but when the rate per second is multiplied by the time delta to get the cummulative interest, it is also multiplied using ray precision which means the result is divided by 1e27 and this makes sense because since timedelta is not in ray precision, the extra zeros from the calculation of rate per second are divided by 1e27 which would scale it back to the original value.

        This is what the function shows. When you run this function and compare the 2 values, you will see that they are the same which is intended behavior which is what I did in reservelibrary.test.js in the "mathtest" test case which you can run and see the returned values are the same
        
        */
    }

    function getvalues() external view returns (uint256, uint256) {
        return (exponent, interestFactor);
    }

    function getvalues1() external view returns (uint256, uint256) {
        return (exponent1, interestFactor1);
    }

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

    function percentmul(
        uint256 val1,
        uint256 val2
    ) external pure returns (uint256) {
        return val1.percentMul(val2);
    }
}
