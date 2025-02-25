// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../../interfaces/core/pools/StabilityPool/IStabilityPool.sol";
import "../../../interfaces/core/minters/RAACMinter/IRAACMinter.sol";
import "../../../interfaces/core/pools/LendingPool/ILendingPool.sol";
import "../../../interfaces/core/tokens/IRAACToken.sol";

/**
 * @title IRAACMinter
 * @author RegnumAurumAcquisitionCorp
 * @dev Manages the minting and distribution of RAAC tokens based on a dynamic emissions schedule.
 * This contract implements a minting strategy that adjusts based on system utilization.
 */
contract RAACMinter is
    IRAACMinter,
    Ownable,
    ReentrancyGuard,
    Pausable,
    AccessControl
{
    using SafeERC20 for IRAACToken;

    IRAACToken public immutable raacToken;
    IStabilityPool public stabilityPool;
    ILendingPool public lendingPool;

    uint256 public constant BLOCKS_PER_DAY = 7200; // Assuming 12-second block time
    uint256 public constant INITIAL_RATE = 1000 * 1e18; // 1000 RAAC per day
    uint256 public constant MAX_BENCHMARK_RATE = (2000 * 1e18) / BLOCKS_PER_DAY; // 2000 RAAC per day maximum
    uint256 public constant MAX_EMISSION_UPDATE_INTERVAL = 1 days;
    uint256 public constant MAX_ADJUSTMENT_FACTOR = 100; // 100% adjustment per update
    uint256 public constant MAX_UTILIZATION_TARGET = 100; // 100% target utilization

    uint256 public lastUpdateBlock;
    uint256 public emissionRate;

    uint256 public minEmissionRate = (100 * 1e18) / BLOCKS_PER_DAY; // 100 RAAC per day minimum
    uint256 public maxEmissionRate = (2000 * 1e18) / BLOCKS_PER_DAY; // 2000 RAAC per day maximum
    uint256 public adjustmentFactor = 5; // 5% adjustment per update
    uint256 public utilizationTarget = 70; // 70% target utilization

    uint256 public excessTokens; // Tokens held for future distribution
    uint256 public benchmarkRate; // Benchmark rate for emissions

    uint256 public lastEmissionUpdateTimestamp;
    uint256 public constant BASE_EMISSION_UPDATE_INTERVAL = 1 days;
    uint256 public emissionUpdateInterval;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    bytes32 public constant EMERGENCY_SHUTDOWN_ROLE =
        keccak256("EMERGENCY_SHUTDOWN_ROLE");

    uint256 public constant TIMELOCK_DURATION = 2 days;
    mapping(bytes32 => uint256) public timeLocks;
    bool public yes; //c for testing purposes
    uint256 public amountToMint; //c for testing purposes

    /**
     * @dev Constructor to initialize the RAACMinter contract
     * @param _raacToken Address of the RAAC token contract
     * @param _stabilityPool Address of the StabilityPool contract
     * @param _lendingPool Address of the RAACLendingPool contract
     * @param initialOwner Address of the initial owner of the contract
     */
    constructor(
        address _raacToken,
        address _stabilityPool,
        address _lendingPool,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            _raacToken == address(0) ||
            _stabilityPool == address(0) ||
            _lendingPool == address(0) ||
            initialOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        raacToken = IRAACToken(_raacToken);
        stabilityPool = IStabilityPool(_stabilityPool);
        lendingPool = ILendingPool(_lendingPool);
        emissionRate = INITIAL_RATE / BLOCKS_PER_DAY; //c so this is the emission rate per block
        lastUpdateBlock = block.number;
        benchmarkRate = emissionRate;
        lastEmissionUpdateTimestamp =
            block.timestamp -
            BASE_EMISSION_UPDATE_INTERVAL;
        emissionUpdateInterval = BASE_EMISSION_UPDATE_INTERVAL;
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);
        _grantRole(UPDATER_ROLE, initialOwner);
    }

    /**
     * @dev Pauses the contract and optionally updates the last update block
     * @param updateLastBlock If true, updates the lastUpdateBlock
     * @param newLastUpdateBlock New value for lastUpdateBlock, if 0 current block number is used
     */
    function pause(
        bool updateLastBlock,
        uint256 newLastUpdateBlock
    ) external onlyRole(PAUSER_ROLE) {
        _pause();
        if (updateLastBlock) {
            _setLastUpdateBlock(newLastUpdateBlock);
        }
    }

    /**
     * @dev Unpauses the contract and optionally updates the last update block
     * @param updateLastBlock If true, updates the lastUpdateBlock
     * @param newLastUpdateBlock New value for lastUpdateBlock, if 0 current block number is used
     */
    function unpause(
        bool updateLastBlock,
        uint256 newLastUpdateBlock
    ) external onlyRole(PAUSER_ROLE) {
        _unpause();
        if (updateLastBlock) {
            _setLastUpdateBlock(newLastUpdateBlock);
        }
    }

    /**
     * @dev Internal function to set the last update block
     * @param newLastUpdateBlock New value for lastUpdateBlock, if 0 current block number is used
     */
    function _setLastUpdateBlock(uint256 newLastUpdateBlock) internal {
        if (newLastUpdateBlock > block.number) revert InvalidBlockNumber();
        lastUpdateBlock = newLastUpdateBlock == 0
            ? block.number
            : newLastUpdateBlock;
        emit LastUpdateBlockSet(lastUpdateBlock);
    }

    /**
     * @dev Allows the owner to update the StabilityPool address
     * @param _stabilityPool New address of the StabilityPool contract
     */
    function setStabilityPool(
        address _stabilityPool
    ) external onlyRole(UPDATER_ROLE) {
        if (_stabilityPool == address(0)) revert ZeroAddress();
        stabilityPool = IStabilityPool(_stabilityPool);
        emit ParameterUpdated(
            "stabilityPool",
            uint256(uint160(_stabilityPool))
        );
    }

    /**
     * @dev Allows the owner to update the LendingPool address
     * @param _lendingPool New address of the RAACLendingPool contract
     */
    function setLendingPool(
        address _lendingPool
    ) external onlyRole(UPDATER_ROLE) {
        if (_lendingPool == address(0)) revert ZeroAddress();
        lendingPool = ILendingPool(_lendingPool);
        emit ParameterUpdated("lendingPool", uint256(uint160(_lendingPool)));
    }

    /**
     * @dev Sets the swap tax rate for the RAAC token
     * @param _swapTaxRate The new swap tax rate to be set
     * @notice Only the contract owner can call this function
     * @notice This function updates the swap tax rate in the RAAC token contract
     */
    function setSwapTaxRate(
        uint256 _swapTaxRate
    ) external onlyRole(UPDATER_ROLE) {
        if (_swapTaxRate > 1000) revert SwapTaxRateExceedsLimit();
        raacToken.setSwapTaxRate(_swapTaxRate);
        emit ParameterUpdated("swapTaxRate", _swapTaxRate);
    }

    /**
     * @dev Sets the burn tax rate for the RAAC token
     * @param _burnTaxRate The new burn tax rate to be set
     * @notice Only the contract owner can call this function
     * @notice This function updates the burn tax rate in the RAAC token contract
     */
    function setBurnTaxRate(
        uint256 _burnTaxRate
    ) external onlyRole(UPDATER_ROLE) {
        if (_burnTaxRate > 1000) revert BurnTaxRateExceedsLimit();
        raacToken.setBurnTaxRate(_burnTaxRate);
        emit ParameterUpdated("burnTaxRate", _burnTaxRate);
    }

    /**
     * @dev Sets the fee collector address
     * @param _feeCollector The address of the new fee collector
     * @notice Only the contract owner can call this function
     * @notice This function updates the fee collector address in the RAAC token contract
     */
    function setFeeCollector(
        address _feeCollector
    ) external onlyRole(UPDATER_ROLE) {
        if (_feeCollector == address(0))
            revert FeeCollectorCannotBeZeroAddress();
        raacToken.setFeeCollector(_feeCollector);
        emit ParameterUpdated("feeCollector", uint256(uint160(_feeCollector)));
    }

    /**
     * @dev Mints RAAC rewards to a specified address
     * @param to Address to receive the minted RAAC tokens
     * @param amount Amount of RAAC tokens to mint
     */
    function mintRewards(
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (msg.sender != address(stabilityPool)) revert OnlyStabilityPool();

        uint256 toMint = excessTokens >= amount ? 0 : amount - excessTokens;
        excessTokens = excessTokens >= amount ? excessTokens - amount : 0;

        if (toMint > 0) {
            raacToken.mint(address(this), toMint);
        }

        raacToken.safeTransfer(to, amount);
        emit RAACMinted(amount);
    } //c this is another function is called nowhere else in this contract or even in the stability contract which is supposed to call it

    /**
     * @dev Returns the current emission rate
     * @return The current emission rate in RAAC per block
     */
    function getEmissionRate() public view returns (uint256) {
        return emissionRate;
    }

    /**
     * @dev Updates the emission rate based on the dynamic emissions schedule
     */
    function updateEmissionRate() public whenNotPaused {
        if (
            emissionUpdateInterval > 0 &&
            block.timestamp <
            lastEmissionUpdateTimestamp + emissionUpdateInterval
        ) {
            revert EmissionUpdateTooFrequent();
        }
        uint256 newRate = calculateNewEmissionRate();
        emissionRate = newRate;
        lastEmissionUpdateTimestamp = block.timestamp;
        emit EmissionRateUpdated(newRate);
    }

    /**
     * @dev Calculates the new emission rate based on the system utilization and benchmark rate
     * @return The new emission rate in RAAC per block
     */
    function calculateNewEmissionRate() internal view returns (uint256) {
        //c should be a view function, i changed for testing purposes
        uint256 utilizationRate = getUtilizationRate(); //bug REPORTED there is a bug in the getutilizationrate function. so have a look at the function to see the bug. NEED TO REPORT THIS !!!!

        uint256 adjustment = (emissionRate * adjustmentFactor) / 100; //c so for every time the emission rate is updated, it is adjusted by the adjustment factor of 5% (see constructor)

        if (utilizationRate > utilizationTarget) {
            uint256 increasedRate = emissionRate + adjustment; //c so the idea is that they increase the rate by 5% if the utilization rate is above the target. this makes sense because if the utilization rate is above the target, it means that the system is being used more than it should be and so they want to incentivize more people to deposit into the stability pool to bring the utilization rate down. so they increase the emission rate to incentivize more people to deposit into the stability pool. this is a good way to incentivize people to deposit into the stability pool
            uint256 maxRate = increasedRate > benchmarkRate
                ? increasedRate
                : benchmarkRate; //c so they make sure that the increased rate is not below the benchmark rate.if (utilizationRate > utilizationTarget), they are saying that the new emission rate has to be above the benchmark rate. The benchmark rate serves a target rate that the emission rate can fluctuate around. it will always be somewhere between the min and max emission rate. this is a good way to make sure that the emission rate does not get too low or too high but always stays around the benchmark rate
            return maxRate < maxEmissionRate ? maxRate : maxEmissionRate;
        } else if (utilizationRate < utilizationTarget) {
            uint256 decreasedRate = emissionRate > adjustment //c so if the utilization rate is below the target, they decrease the emission rate by 5% to decrease the incentive for people to deposit rtokens into the stability pool
                ? emissionRate - adjustment
                : 0;
            uint256 minRate = decreasedRate < benchmarkRate
                ? decreasedRate
                : benchmarkRate; //c the idea of this is that they are saying that if if (utilizationRate < utilizationTarget), then the emission rate has to be below the benchmark rate. The benchmark rate serves a target rate that the emission rate can fluctuate around. it will always be somewhere between the min and max emission rate. this is a good way to make sure that the emission rate does not get too low or too high but always stays around the benchmark rate
            return minRate > minEmissionRate ? minRate : minEmissionRate;
        }

        return emissionRate; //c so if utilization rate is equal to utilization target, the emission rate remains the same
    }

    /**
     * @dev Calculates the current system utilization rate
     * @return The utilization rate as a percentage (0-100)
     */
    function getUtilizationRate() public view returns (uint256) {
        uint256 totalBorrowed = lendingPool.getNormalizedDebt();
        //bug REPORTED this should be the normalized totalsupply of the debttoken.sol because whenever anyone borrows, the debt is normalized by dividing the amount by the usage index at the time and they are minted the normalized amount. so since the below total deposits gets the total amount of rtokens deposited into the stability pool, the total borrowed should be the total amount of debt tokens borrowed from the lending pool. lending.getnormalizeddebt() only returns the usage index which is weird and not useful for this calculation
        uint256 totalDeposits = stabilityPool.getTotalDeposits();
        if (totalDeposits == 0) return 0;
        return (totalBorrowed * 100) / totalDeposits;
    }

    /**
     * @dev Returns the total supply of RAAC tokens
     * @return The total supply of RAAC tokens
     */
    function getTotalSupply() public view returns (uint256) {
        return raacToken.totalSupply();
    }

    /**
     * @dev Triggers the minting process and updates the emission rate if the interval has passed
     */
    function tick() external nonReentrant whenNotPaused {
        if (
            emissionUpdateInterval == 0 ||
            block.timestamp >=
            lastEmissionUpdateTimestamp + emissionUpdateInterval
        ) {
            updateEmissionRate();
        } //c this checks out because this tick function mints raac to the stability pool so it should ideally update the emission rate before minting the raac to the stability pool if the update interval has passed .
        uint256 currentBlock = block.number;
        uint256 blocksSinceLastUpdate = currentBlock - lastUpdateBlock;
        if (blocksSinceLastUpdate > 0) {
            amountToMint = emissionRate * blocksSinceLastUpdate;

            if (amountToMint > 0) {
                excessTokens += amountToMint; //bug the excess tokens according to the natspec is Tokens held for future distribution which is meant to represent tokens that are minted but not yet distributed. so the excess tokens should be the amount of raac minted minus the amount of raac distributed. but in this case, the excess tokens is being increased by the amount of raac minted and never decreased after a user withdraws
                lastUpdateBlock = currentBlock;
                raacToken.mint(address(stabilityPool), amountToMint);
                emit RAACMinted(amountToMint);
            }
        }
    }

    /**
     * @dev Updates the benchmark rate for emissions
     * @param _newRate New benchmark rate
     */
    function updateBenchmarkRate(
        uint256 _newRate
    ) external onlyRole(UPDATER_ROLE) {
        if (_newRate == 0 || _newRate > MAX_BENCHMARK_RATE)
            revert InvalidBenchmarkRate();
        uint256 oldRate = benchmarkRate;
        benchmarkRate = _newRate;
        emit BenchmarkRateUpdated(oldRate, _newRate);
    }

    /**
     * @dev Sets the minimum emission rate
     * @param _minEmissionRate New minimum emission rate
     */
    function setMinEmissionRate(
        uint256 _minEmissionRate
    ) external onlyRole(UPDATER_ROLE) {
        if (_minEmissionRate >= maxEmissionRate)
            revert InvalidMinEmissionRate();
        uint256 oldRate = minEmissionRate;
        minEmissionRate = _minEmissionRate;
        emit MinEmissionRateUpdated(oldRate, _minEmissionRate);
    }

    /**
     * @dev Sets the maximum emission rate
     * @param _maxEmissionRate New maximum emission rate
     */
    function setMaxEmissionRate(
        uint256 _maxEmissionRate
    ) external onlyRole(UPDATER_ROLE) {
        if (_maxEmissionRate <= minEmissionRate)
            revert InvalidMaxEmissionRate();
        uint256 oldRate = maxEmissionRate;
        maxEmissionRate = _maxEmissionRate;
        emit MaxEmissionRateUpdated(oldRate, _maxEmissionRate);
    }

    /**
     * @dev Sets the adjustment factor
     * @param _adjustmentFactor New adjustment factor
     */
    function setAdjustmentFactor(
        uint256 _adjustmentFactor
    ) external onlyRole(UPDATER_ROLE) {
        if (_adjustmentFactor == 0 || _adjustmentFactor > MAX_ADJUSTMENT_FACTOR)
            revert InvalidAdjustmentFactor();
        uint256 oldFactor = adjustmentFactor;
        adjustmentFactor = _adjustmentFactor;
        emit AdjustmentFactorUpdated(oldFactor, _adjustmentFactor);
    }

    /**
     * @dev Sets the utilization target
     * @param _utilizationTarget New utilization target
     */
    function setUtilizationTarget(
        uint256 _utilizationTarget
    ) external onlyRole(UPDATER_ROLE) {
        if (
            _utilizationTarget == 0 ||
            _utilizationTarget > MAX_UTILIZATION_TARGET
        ) revert InvalidUtilizationTarget();
        uint256 oldTarget = utilizationTarget;
        utilizationTarget = _utilizationTarget;
        emit UtilizationTargetUpdated(oldTarget, _utilizationTarget);
    }

    /**
     * @dev Sets the emission update interval
     * @param _emissionUpdateInterval New emission update interval
     */
    function setEmissionUpdateInterval(
        uint256 _emissionUpdateInterval
    ) external onlyRole(UPDATER_ROLE) {
        if (
            _emissionUpdateInterval == 0 ||
            _emissionUpdateInterval > MAX_EMISSION_UPDATE_INTERVAL
        ) revert InvalidEmissionUpdateInterval();
        uint256 oldInterval = emissionUpdateInterval;
        emissionUpdateInterval = _emissionUpdateInterval;
        emit EmissionUpdateIntervalUpdated(
            oldInterval,
            _emissionUpdateInterval
        );
    }

    /**
     * @dev Returns the current amount of excess tokens held for future distribution
     * @return The amount of excess tokens
     */
    function getExcessTokens() external view returns (uint256) {
        return excessTokens;
    }

    /**
     * @dev Emergency shutdown function to pause critical operations
     * Can only be called by the contract owner
     * @param updateLastBlock If true, updates the lastUpdateBlock
     * @param newLastUpdateBlock New value for lastUpdateBlock, if 0 current block number is used
     */
    function emergencyShutdown(
        bool updateLastBlock,
        uint256 newLastUpdateBlock
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emissionRate = 0;
        _pause();
        if (updateLastBlock) {
            _setLastUpdateBlock(newLastUpdateBlock);
        }
        emit EmergencyShutdown(msg.sender, lastUpdateBlock);
    }
}
