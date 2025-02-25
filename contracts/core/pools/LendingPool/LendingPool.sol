// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// OpenZeppelin libraries
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../../../libraries/math/PercentageMath.sol";
import "../../../libraries/math/WadRayMath.sol";
import "../../../libraries/pools/ReserveLibrary.sol";
// Interface contracts
import "../../../interfaces/core/pools/LendingPool/ILendingPool.sol";
// External interfaces
import "../../../interfaces/core/oracles/IRAACHousePrices.sol";
import "../../../interfaces/core/tokens/IDebtToken.sol";
import "../../../interfaces/core/tokens/IRAACNFT.sol";
import "../../../interfaces/core/tokens/IRToken.sol";

import "../../tokens/DebtToken.sol";
import "../../tokens/RToken.sol";
// Curve's crvUSD vault interface
import "../../../interfaces/curve/ICurveCrvUSDVault.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol"; //c for testing purposes

/**
 * @title LendingPool
 * @notice Main contract for the RAAC lending protocol. Users can deposit assets, borrow, repay, and more.
 * @dev This contract manages interactions with RTokens, DebtTokens, and handles the main logic for asset lending.
 */
contract LendingPool is
    ILendingPool,
    Ownable,
    ReentrancyGuard,
    ERC721Holder,
    Pausable
{
    using Address for address payable;
    using PercentageMath for uint256;
    using WadRayMath for uint256;
    using SafeERC20 for IERC20;

    using ReserveLibrary for ReserveLibrary.ReserveData;
    using ReserveLibrary for ReserveLibrary.ReserveRateData;
    using SafeCast for uint256; //c for testing purposes

    // Reserve data, including liquidity, usage indices, and addresses
    ReserveLibrary.ReserveData public reserve;

    // Rate data, including interest rates and thresholds
    ReserveLibrary.ReserveRateData public rateData;

    // Mapping of user addresses to their data
    mapping(address => UserData) public userData;

    // Collateral NFT contract interface
    IRAACNFT public immutable raacNFT;

    // Price Oracle interface
    IRAACHousePrices public priceOracle;

    // Prime Rate Oracle
    address public primeRateOracle;

    // CrvUSD token interface
    IERC20 public reserveAssetToken;

    // RToken interface
    IRToken public rToken;

    // DebtToken interface
    IDebtToken public debtToken;

    // Stability Pool address
    address public stabilityPool;

    // Can payback debt of other users
    bool public canPaybackDebt = true;

    // Liquidation parameters
    uint256 public constant BASE_LIQUIDATION_THRESHOLD = 80 * 1e2; // 80% in basis points //c this is using the scaling factor so it will be 8000/10000 as we already know 10000 is used as scaling factor for percentages.
    uint256 public constant BASE_HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // Health factor threshold
    uint256 public constant BASE_LIQUIDATION_GRACE_PERIOD = 3 days;
    uint256 private constant DUST_THRESHOLD = 1e6;

    uint256 public liquidationThreshold;
    uint256 public healthFactorLiquidationThreshold;
    uint256 public liquidationGracePeriod;

    // Mapping to track users under liquidation
    mapping(address => bool) public isUnderLiquidation;
    mapping(address => uint256) public liquidationStartTime;

    // Curve crvUSD Vault interface
    ICurveCrvUSDVault public curveVault;

    // Liquidity buffer ratio (20% represented in basis points = 20_00)
    uint256 public liquidityBufferRatio = 20_00; // 20%

    // Total amount deposited in the vault
    uint256 public totalVaultDeposits;

    // Allow to pause withdrawals
    bool public withdrawalsPaused = false;

    error InvalidInterestRateParameters(); //c for testing purposes
    uint256 public grossLiquidityRate;
    uint256 public protocolFeeAmount;

    // MODIFIERS

    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlyStabilityPool() {
        if (msg.sender != stabilityPool) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyPrimeRateOracle() {
        if (msg.sender != primeRateOracle) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @notice Sets a parameter value
     * @dev Only callable by contract owner
     * @param param The parameter to update
     * @param newValue The new value to set
     */
    function setParameter(
        OwnerParameter param,
        uint256 newValue
    ) external override onlyOwner {
        if (param == OwnerParameter.LiquidationThreshold) {
            require(newValue <= 100_00, "Invalid liquidation threshold");
            //bug will probably be a low but new value should never be equal to 10000 because that would mean
            liquidationThreshold = newValue;
            emit LiquidationParametersUpdated(
                liquidationThreshold,
                healthFactorLiquidationThreshold,
                liquidationGracePeriod
            );
        } else if (param == OwnerParameter.HealthFactorLiquidationThreshold) {
            //c there are no checks on how high this value can be set so it can be set to any value. might not be an issue but something to look out for
            healthFactorLiquidationThreshold = newValue;
            emit LiquidationParametersUpdated(
                liquidationThreshold,
                healthFactorLiquidationThreshold,
                liquidationGracePeriod
            );
        } else if (param == OwnerParameter.LiquidationGracePeriod) {
            require(
                newValue >= 1 days && newValue <= 7 days,
                "Invalid grace period"
            );
            liquidationGracePeriod = newValue;
            emit LiquidationParametersUpdated(
                liquidationThreshold,
                healthFactorLiquidationThreshold,
                liquidationGracePeriod
            );
        } else if (param == OwnerParameter.LiquidityBufferRatio) {
            require(newValue <= 100_00, "Ratio cannot exceed 100%");
            uint256 oldValue = liquidityBufferRatio;
            liquidityBufferRatio = newValue;
            emit LiquidityBufferRatioUpdated(oldValue, newValue);
        } else if (param == OwnerParameter.WithdrawalStatus) {
            require(newValue <= 1, "Invalid boolean value");
            withdrawalsPaused = newValue == 1;
            emit WithdrawalsPauseStatusChanged(withdrawalsPaused);
        } else if (param == OwnerParameter.CanPaybackDebt) {
            require(newValue <= 1, "Invalid boolean value");
            canPaybackDebt = newValue == 1;
            emit CanPaybackDebtChanged(canPaybackDebt);
        }
    }

    // CONSTRUCTOR
    /**
     * @dev Constructor
     * @param _reserveAssetAddress The address of the reserve asset (e.g., crvUSD)
     * @param _rTokenAddress The address of the RToken contract
     * @param _debtTokenAddress The address of the DebtToken contract
     * @param _raacNFTAddress The address of the RAACNFT contract
     * @param _priceOracleAddress The address of the price oracle
     * @param _initialPrimeRate The initial prime rate
     */
    constructor(
        address _reserveAssetAddress,
        address _rTokenAddress,
        address _debtTokenAddress,
        address _raacNFTAddress,
        address _priceOracleAddress,
        uint256 _initialPrimeRate
    ) Ownable(msg.sender) {
        if (
            _reserveAssetAddress == address(0) ||
            _rTokenAddress == address(0) ||
            _debtTokenAddress == address(0) ||
            _raacNFTAddress == address(0) ||
            _priceOracleAddress == address(0) ||
            _initialPrimeRate == 0
        ) revert AddressCannotBeZero();

        reserveAssetToken = IERC20(_reserveAssetAddress);
        //bug why is this initialized here if it is never used ?? in the code, reserve.reserveAssetAddress is used all the time so why is this variable here ??
        raacNFT = IRAACNFT(_raacNFTAddress);
        priceOracle = IRAACHousePrices(_priceOracleAddress);
        rToken = IRToken(_rTokenAddress);
        debtToken = IDebtToken(_debtTokenAddress);

        // Initialize reserve data
        reserve.liquidityIndex = uint128(WadRayMath.RAY); // 1e27

        reserve.usageIndex = uint128(WadRayMath.RAY);

        reserve.lastUpdateTimestamp = uint40(block.timestamp);

        // Addresses
        reserve.reserveRTokenAddress = address(_rTokenAddress);
        reserve.reserveAssetAddress = address(_reserveAssetAddress);
        reserve.reserveDebtTokenAddress = address(_debtTokenAddress);

        // Prime Rate
        rateData.primeRate = uint256(_initialPrimeRate);
        rateData.baseRate = rateData.primeRate.percentMul(25_00); // 25% of prime rate
        rateData.optimalRate = rateData.primeRate.percentMul(50_00); // 50% of prime rate
        rateData.maxRate = rateData.primeRate.percentMul(400_00); // 400% of prime rate
        rateData.optimalUtilizationRate = WadRayMath.RAY.percentMul(80_00); // 80% in RAY (27 decimals)
        rateData.protocolFeeRate = 0; // 0% in RAY (27 decimals)

        // Initialize liquidation parameters
        liquidationThreshold = BASE_LIQUIDATION_THRESHOLD;
        healthFactorLiquidationThreshold = BASE_HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
        liquidationGracePeriod = BASE_LIQUIDATION_GRACE_PERIOD;
    }

    // CORE FUNCTIONS

    /**
     * @notice Allows a user to deposit reserve assets and receive RTokens
     * @param amount The amount of reserve assets to deposit
     */
    function deposit(
        uint256 amount //c unsafe casting as if a user deposits a value greater than uint128, it will overflow as ReserveLibrary.deposit calls the mint function in the rtoken contract which attempts to downcast it to a uint128 for some reason but in reality, no one is depositing more than 2^128 - 1 so this is not an issue
    ) external nonReentrant whenNotPaused onlyValidAmount(amount) {
        // Update the reserve state before the deposit
        ReserveLibrary.updateReserveState(reserve, rateData);

        // Perform the deposit through ReserveLibrary
        uint256 mintedAmount = ReserveLibrary.deposit(
            reserve,
            rateData,
            amount,
            msg.sender
        );

        //c total liquidity is updated in the deposit function in reservelibrary.sol where there is an  updateInterestRatesAndLiquidity function which increases the total liquidity by the amount deposited. this is done to keep track of the total liquidity in the protocol

        // Rebalance liquidity after deposit
        _rebalanceLiquidity(); //c need to look at this

        emit Deposit(msg.sender, amount, mintedAmount);
    }

    /**
     * @notice Allows a user to withdraw reserve assets by burning RTokens
     * @param amount The amount of reserve assets to withdraw
     */
    function withdraw(
        uint256 amount
    ) external nonReentrant whenNotPaused onlyValidAmount(amount) {
        if (withdrawalsPaused) revert WithdrawalsArePaused();

        // Update the reserve state before the withdrawal
        ReserveLibrary.updateReserveState(reserve, rateData);

        // Ensure sufficient liquidity is available
        _ensureLiquidity(amount);

        // Perform the withdrawal through ReserveLibrary
        (
            uint256 amountWithdrawn,
            uint256 amountScaled,
            uint256 amountUnderlying
        ) = ReserveLibrary.withdraw(
                reserve, // ReserveData storage
                rateData, // ReserveRateData storage
                amount, // Amount to withdraw
                msg.sender // Recipient
            );

        // Rebalance liquidity after withdrawal
        _rebalanceLiquidity();

        emit Withdraw(msg.sender, amountWithdrawn);
    }

    function depositNFT(uint256 tokenId) external nonReentrant whenNotPaused {
        // update state
        ReserveLibrary.updateReserveState(reserve, rateData);

        if (raacNFT.ownerOf(tokenId) != msg.sender) revert NotOwnerOfNFT();

        UserData storage user = userData[msg.sender];
        if (user.depositedNFTs[tokenId]) revert NFTAlreadyDeposited();

        user.nftTokenIds.push(tokenId);
        user.depositedNFTs[tokenId] = true;

        raacNFT.safeTransferFrom(msg.sender, address(this), tokenId);

        emit NFTDeposited(msg.sender, tokenId);
    }

    /**
     * @notice Allows a user to withdraw an NFT
     * @param tokenId The token ID of the NFT to withdraw
     */
    function withdrawNFT(uint256 tokenId) external nonReentrant whenNotPaused {
        if (isUnderLiquidation[msg.sender])
            revert CannotWithdrawUnderLiquidation();

        UserData storage user = userData[msg.sender];
        if (!user.depositedNFTs[tokenId]) revert NFTNotDeposited();

        // update state
        ReserveLibrary.updateReserveState(reserve, rateData);

        // Check if withdrawal would leave user undercollateralized
        uint256 userDebt = user.scaledDebtBalance.rayMul(reserve.usageIndex);
        uint256 collateralValue = getUserCollateralValue(msg.sender);
        uint256 nftValue = getNFTPrice(tokenId);

        if (
            collateralValue - nftValue <
            userDebt.percentMul(liquidationThreshold)
        ) {
            revert WithdrawalWouldLeaveUserUnderCollateralized();
        } //bug REPORTED say i have 2 nfts with nft1 = $1000 and nft2 = $3000 and i have debt of $2000. if i withdraw nft2, i will have $3000 - $2000 = $1000 left as collateral which is less than the debt so i should not be able to withdraw nft2 as this leaves RAAC with bad debt of 1000 but the above calculation says comapres my collateral to  userDebt.percentMul(liquidationThreshold) so if liquidation threshold is 20%, then it compares my collateral to 20% of my debt which is $400. so if my collateral is greater than $400, i should be able to withdraw nft2 but this is wrong

        // Remove NFT from user's deposited NFTs
        for (uint256 i = 0; i < user.nftTokenIds.length; i++) {
            if (user.nftTokenIds[i] == tokenId) {
                user.nftTokenIds[i] = user.nftTokenIds[
                    user.nftTokenIds.length - 1
                ];
                user.nftTokenIds.pop();
                break;
            }
        }
        user.depositedNFTs[tokenId] = false;

        raacNFT.safeTransferFrom(address(this), msg.sender, tokenId);

        emit NFTWithdrawn(msg.sender, tokenId);
    }

    /**
     * @notice Allows a user to borrow reserve assets using their NFT collateral
     * @param amount The amount of reserve assets to borrow
     */
    function borrow(
        //c note that only users with nfts can borrow crvusd from the pool. users who deposit crvusd to the pool(really the rtoken contract) get rtokens which they take to the stablity pool to get raac tokens minted to them at an emission rate decided in the RAACMinter contract. this is how the protocol works
        uint256 amount
    ) external nonReentrant whenNotPaused onlyValidAmount(amount) {
        if (isUnderLiquidation[msg.sender])
            revert CannotBorrowUnderLiquidation();

        UserData storage user = userData[msg.sender];

        uint256 collateralValue = getUserCollateralValue(msg.sender);

        if (collateralValue == 0) revert NoCollateral();

        // Update reserve state before borrowing
        ReserveLibrary.updateReserveState(reserve, rateData);

        // Ensure sufficient liquidity is available
        _ensureLiquidity(amount);

        // Fetch user's total debt after borrowing
        uint256 userTotalDebt = user.scaledDebtBalance.rayMul(
            reserve.usageIndex
        ) + amount;

        // Ensure the user has enough collateral to cover the new debt
        if (collateralValue < userTotalDebt.percentMul(liquidationThreshold)) {
            revert NotEnoughCollateralToBorrow();
        } //bug REPORTED so if my collateral is less than my debt i can still borrow ??? this creates bad debt. should use healthfactor when checking if a user can borrow

        //q if the protocol has bad debt, is there any way to still liquidate a user who has bad debt ?? This is an important check

        // Update user's scaled debt balance
        uint256 scaledAmount = amount.rayDiv(reserve.usageIndex);
        //c this is the normalized debt amount

        // Mint DebtTokens to the user (scaled amount)
        (
            bool isFirstMint,
            uint256 amountMinted,
            uint256 newTotalSupply
        ) = IDebtToken(reserve.reserveDebtTokenAddress).mint(
                msg.sender,
                msg.sender,
                amount,
                reserve.usageIndex
            );

        // Transfer borrowed amount to user
        IRToken(reserve.reserveRTokenAddress).transferAsset(msg.sender, amount);

        user.scaledDebtBalance += scaledAmount;
        // reserve.totalUsage += amount;
        reserve.totalUsage = newTotalSupply;

        // Update liquidity and interest rates
        ReserveLibrary.updateInterestRatesAndLiquidity(
            reserve,
            rateData,
            0,
            amount
        );

        // Rebalance liquidity after borrowing
        _rebalanceLiquidity();

        emit Borrow(msg.sender, amount);
    }

    /**
     * @notice Allows a user to repay their own borrowed reserve assets
     * @param amount The amount to repay
     */
    function repay(
        uint256 amount
    ) external nonReentrant whenNotPaused onlyValidAmount(amount) {
        _repay(amount, msg.sender);
    }

    /**
     * @notice Allows a user to repay borrowed reserve assets on behalf of another user
     * @param amount The amount to repay
     * @param onBehalfOf The address of the user whose debt is being repaid
     */
    function repayOnBehalf(
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant whenNotPaused onlyValidAmount(amount) {
        if (!canPaybackDebt) revert PaybackDebtDisabled();
        if (onBehalfOf == address(0)) revert AddressCannotBeZero();
        _repay(amount, onBehalfOf);
    }

    /**
     * @notice Internal function to repay borrowed reserve assets
     * @param amount The amount to repay
     * @param onBehalfOf The address of the user whose debt is being repaid. If address(0), msg.sender's debt is repaid.
     * @dev This function allows users to repay their own debt or the debt of another user.
     *      The caller (msg.sender) provides the funds for repayment in both cases.
     *      If onBehalfOf is set to address(0), the function defaults to repaying the caller's own debt.
     */
    function _repay(uint256 amount, address onBehalfOf) internal {
        if (amount == 0) revert InvalidAmount();
        if (onBehalfOf == address(0)) revert AddressCannotBeZero();

        UserData storage user = userData[onBehalfOf];

        // Update reserve state before repayment
        ReserveLibrary.updateReserveState(reserve, rateData);

        // Calculate the user's debt (for the onBehalfOf address)
        uint256 userDebt = IDebtToken(reserve.reserveDebtTokenAddress)
            .balanceOf(onBehalfOf);
        uint256 userScaledDebt = userDebt.rayDiv(reserve.usageIndex);

        // If amount is greater than userDebt, cap it at userDebt
        uint256 actualRepayAmount = amount > userScaledDebt
            ? userScaledDebt
            : amount; //c this is the same check that was in DebtToken::burn (well similar). you can ignore this line as it is never used and just adds confusion

        uint256 scaledAmount = actualRepayAmount.rayDiv(reserve.usageIndex);
        //q why is this here ?? ignore this line, it is never used and just adds confusion

        // Burn DebtTokens from the user whose debt is being repaid (onBehalfOf)
        // is not actualRepayAmount because we want to allow paying extra dust and we will then cap there
        (
            uint256 amountScaled,
            uint256 newTotalSupply,
            uint256 amountBurned,
            uint256 balanceIncrease
        ) = IDebtToken(reserve.reserveDebtTokenAddress).burn(
                onBehalfOf,
                amount,
                reserve.usageIndex
            );
        //c notice how actualRepayAmount is not passed in here. this is because the burn function in the debt token contract has an if condition that makes sure that the amount to burn is not greater than the user's debt. if it is, it will burn the user's entire debt. so when taking tokens from the user in the function below, the amount taken is amountscaled which is the amount of debt tokens that have been burnt which is capped at the user's debt balance so even if a user enters an extremely large amount, the amount taken from the user will be capped at the user's debt balance

        // Transfer reserve assets from the caller (msg.sender) to the reserve
        IERC20(reserve.reserveAssetAddress).safeTransferFrom(
            msg.sender,
            reserve.reserveRTokenAddress,
            amountScaled
        );

        reserve.totalUsage = newTotalSupply;
        user.scaledDebtBalance -= amountBurned; //bug REPORTED there is an over/underflow herre somehow. NEED TO FIGURE OUT WHERE THIS IS AND REPORT IT. run "borrowers are overcharged debt" in LendingPool.test.js to see the issue

        // Update liquidity and interest rates
        ReserveLibrary.updateInterestRatesAndLiquidity(
            reserve,
            rateData,
            amountScaled,
            0
        );

        emit Repay(msg.sender, onBehalfOf, actualRepayAmount);
    }

    /**
     * @notice Updates the state of the lending pool
     * @dev This function updates the reserve state, including liquidity and usage indices
     */
    function updateState() external {
        //c anyone can updatestate. state can be updated when the contract is paused as there is no modifier here so if there is an issue, people will still be able to update the state. is this expected ??
        ReserveLibrary.updateReserveState(reserve, rateData);
    }

    // LIQUIDATION FUNCTIONS

    /**
     * @notice Allows anyone to initiate the liquidation process if a user's health factor is below threshold
     * @param userAddress The address of the user to liquidate
     */
    function initiateLiquidation(
        address userAddress //c a1; assumes that this address is always an EOA. if it is a contract, what changes ??
    ) external nonReentrant whenNotPaused {
        if (isUnderLiquidation[userAddress])
            revert UserAlreadyUnderLiquidation();
        //c assumes that liquidity may not ever need to be reinitiated. if it does, then this function will revert as the user is already under liquidation. this will work if i can find a way to get a user to unliquidate themselves

        //c so far i cant seem to find a way to unliquidate a user maliciously but I will come back to this

        // update state

        ReserveLibrary.updateReserveState(reserve, rateData); //c as we know, this updates the liq index and usage indexes and this is important as the health factor uses the usage index to calculate the user's debt so it needs to be up to date.

        UserData storage user = userData[userAddress];

        uint256 healthFactor = calculateHealthFactor(userAddress); //c assumes this function returns the correct health factor which it looks like it  is doing from my assessment

        if (healthFactor >= healthFactorLiquidationThreshold)
            revert HealthFactorTooLow(); //bug this is a low but the revert message should be "Health factor is too high" as the health factor is above the threshold

        //c assumes that if the health factor is greater than the threshold, then the user should not be liquidated at any cost.

        isUnderLiquidation[userAddress] = true;
        liquidationStartTime[userAddress] = block.timestamp;

        emit LiquidationInitiated(msg.sender, userAddress);
        //c I was thinking if I could initiate liquidation for myself and just never close it but I cant because the stabilitypool is the only contract that can call finalizeliquidation which means once this function is called and the grace period is over the stability pool can finalize the liquidation so thats not possible
    }

    /**
     * @notice Allows a user to repay their debt and close the liquidation within the grace period
     */
    function closeLiquidation() external nonReentrant whenNotPaused {
        address userAddress = msg.sender;

        if (!isUnderLiquidation[userAddress]) revert NotUnderLiquidation();

        // update state
        ReserveLibrary.updateReserveState(reserve, rateData);

        if (
            block.timestamp >
            liquidationStartTime[userAddress] + liquidationGracePeriod //bug REPORTED x2  there is no incentive for anyone to liquidate another user so although liquidationStartTime is the time the liquidation was initiated, it isnt the moment the user went below their health factor. any amount of time could have passed before the liquidation was initiated so this can allow for 2 things to happen. The grace period being extended for the user from when they actually went below health factor to whenever the liquidation was initiated if ever. The second and most important is that if the price of the house increases, their collateral value increases which can increase their health factor to make them healthy again but at that point, they are already seen as being in liquidation and this is wrong . there should be a check to make sure that the user is in liquidation in this function and also when finalizing liquidation to make sure no updates have been made to their collateral value between initiating liquidation and finalizing it . These are actually 2 different bugs and should be reported seperately. VERY IMPORTANT
        ) {
            revert GracePeriodExpired();
        }

        UserData storage user = userData[userAddress];

        uint256 userDebt = user.scaledDebtBalance.rayMul(reserve.usageIndex);

        if (userDebt > DUST_THRESHOLD) revert DebtNotZero();

        isUnderLiquidation[userAddress] = false;
        liquidationStartTime[userAddress] = 0;

        emit LiquidationClosed(userAddress);
    }

    /**
     * @notice Allows the Stability Pool to finalize the liquidation after the grace period has expired
     * @param userAddress The address of the user being liquidated
     */
    function finalizeLiquidation(
        address userAddress
    ) external nonReentrant onlyStabilityPool {
        if (!isUnderLiquidation[userAddress]) revert NotUnderLiquidation();

        // update state
        ReserveLibrary.updateReserveState(reserve, rateData);

        if (
            block.timestamp <=
            liquidationStartTime[userAddress] + liquidationGracePeriod
        ) {
            revert GracePeriodNotExpired();
        }

        UserData storage user = userData[userAddress];

        uint256 userDebt = user.scaledDebtBalance.rayMul(reserve.usageIndex);

        isUnderLiquidation[userAddress] = false;
        liquidationStartTime[userAddress] = 0;
        // Transfer NFTs to Stability Pool
        for (uint256 i = 0; i < user.nftTokenIds.length; i++) {
            uint256 tokenId = user.nftTokenIds[i];
            user.depositedNFTs[tokenId] = false;
            raacNFT.transferFrom(address(this), stabilityPool, tokenId);
        }
        delete user.nftTokenIds;

        // Burn DebtTokens from the user
        (
            uint256 amountScaled,
            uint256 newTotalSupply,
            uint256 amountBurned,
            uint256 balanceIncrease
        ) = IDebtToken(reserve.reserveDebtTokenAddress).burn(
                userAddress,
                userDebt,
                reserve.usageIndex
            );

        // Transfer reserve assets from Stability Pool to cover the debt
        IERC20(reserve.reserveAssetAddress).safeTransferFrom(
            msg.sender,
            reserve.reserveRTokenAddress,
            amountScaled //c amountscaled here is the user's actual debt (user's scaled debt * current usage index) a You can see this in the debt token contract where the burn and balanceOf functions are with my explanations.
        );

        // Update user's scaled debt balance
        user.scaledDebtBalance -= amountBurned;
        reserve.totalUsage = newTotalSupply;

        // Update liquidity and interest rates
        ReserveLibrary.updateInterestRatesAndLiquidity(
            reserve,
            rateData,
            amountScaled,
            0
        ); //c Need to look at this function as amountscaled is passed in here. need to know if that could be an issue

        //bug REPORTED why is liquidity not rebalanced here ?? funds enter the rtoken address here so liquidity should be rebalanced

        emit LiquidationFinalized(
            stabilityPool,
            userAddress,
            userDebt,
            getUserCollateralValue(userAddress)
        );
    }

    // VIEW FUNCTIONS

    /**
     * @notice Calculates the user's health factor
     * @param userAddress The address of the user
     * @return The health factor (in RAY) //bug this wrong. the health factor is not returned in ray. it is in wad or just normal 18 decimals
     */
    function calculateHealthFactor(
        address userAddress
    ) public view returns (uint256) {
        uint256 collateralValue = getUserCollateralValue(userAddress);
        uint256 userDebt = getUserDebt(userAddress);

        if (userDebt < 1) return type(uint256).max;

        uint256 collateralThreshold = collateralValue.percentMul(
            liquidationThreshold
        ); //c the idea is that a users health factor is the amount they have borrowed in relation to the amount they can borrow. the amount they can borrow is only a percentage of their total collateral and this percentage is the liquidation threshold. so if their health factor is above a certain value, they are safe from liquidation and vice versa.

        return (collateralThreshold * 1e18) / userDebt;
    }

    /**
     * @notice Gets the total collateral value of a user
     * @param userAddress The address of the user
     * @return The total collateral value
     */
    function getUserCollateralValue(
        address userAddress
    ) public view returns (uint256) {
        UserData storage user = userData[userAddress];
        uint256 totalValue = 0;

        for (uint256 i = 0; i < user.nftTokenIds.length; i++) {
            uint256 tokenId = user.nftTokenIds[i];
            uint256 price = getNFTPrice(tokenId);
            totalValue += price;
        }

        return totalValue;
    }

    /**
     * @notice Gets the user's debt including interest
     * @param userAddress The address of the user
     * @return The user's total debt
     */
    function getUserDebt(address userAddress) public view returns (uint256) {
        UserData storage user = userData[userAddress];
        return user.scaledDebtBalance.rayMul(reserve.usageIndex);
        //c this gets the user's actual debt as actual debt = normalized debt * usage index. see bug in stabilitypool::liquidateBorrower
    }

    /**
     * @notice Gets the current price of an NFT from the oracle
     * @param tokenId The token ID of the NFT
     * @return The price of the NFT
     *
     * Checks if the price is stale
     */
    function getNFTPrice(uint256 tokenId) public view returns (uint256) {
        (uint256 price, uint256 lastUpdateTimestamp) = priceOracle
            .getLatestPrice(tokenId);
        if (price == 0) revert InvalidNFTPrice();
        return price;
    }

    /**
     * @notice Gets the reserve's normalized income
     * @return The normalized income (liquidity index)
     */
    function getNormalizedIncome() external view returns (uint256) {
        return reserve.liquidityIndex;
    } //bug REPORTED same as in getNormalizedDebt where the liquidity index is stale.

    /**
     * @notice Gets the reserve's normalized debt
     * @return The normalized debt (usage index)
     */
    function getNormalizedDebt() external view returns (uint256) {
        return reserve.usageIndex;
    } //bug  this exact function is in reservelibrary.sol and it does different things. the bug here is because if ReserveLibrary.updateReserveState is not called before this function is called, then the usageIndex will be stale and cause wrong calculations. NEED TO FIND WHERE THIS IS AN ISSUE AND REPORT IT

    //c so what the protocol is trying to do here is to set the normalized debt of the the reserve to be the usage index which we already know is the cumulative interest of the debt. This normalized debt value (usage index) is meant to be multiplied by the user's normalized debt to get the actual value of their debt. as we have learnt, actual debt is just normalized debt * usage index which is normalized debt of the reserve in this case. weird naming strategy but ok. this is why the code above returns the usage index. there is another getnormalizeddebt function in the reservelibrary.sol file which does something completely different which is weird but as the idea is that it is supposed to do the same thing. these 2 functions are called in different contexts. in stabilitypool::liquidateborrower, this function is called to get the usage index to scale a user's normalized debt up to its actual debt. in reservelibrary.sol , the getnormalizeddebt function is to get the total debt of the protocol which is wrong but thats another issue I will report

    /**
     * @notice Gets the reserve's prime rate
     * @return The prime rate
     */
    function getPrimeRate() external view returns (uint256) {
        return rateData.primeRate;
    }

    /**
     * @notice Gets all of user data
     * @param userAddress The address of the user
     * @return nftTokenIds The user's NFT token IDs
     * @return scaledDebtBalance The user's scaled debt balance
     * @return userCollateralValue The user's collateral value
     * @return isUserUnderLiquidation Whether the user is under liquidation
     * @return liquidityIndex The reserve's liquidity index
     * @return usageIndex The reserve's usage index
     * @return totalLiquidity The reserve's total liquidity
     * @return totalUsage The reserve's total usage
     */
    function getAllUserData(
        address userAddress
    )
        public
        view
        returns (
            uint256[] memory nftTokenIds,
            uint256 scaledDebtBalance,
            uint256 userCollateralValue,
            bool isUserUnderLiquidation,
            uint256 liquidityIndex,
            uint256 usageIndex,
            uint256 totalLiquidity,
            uint256 totalUsage
        )
    {
        UserData storage user = userData[userAddress];
        return (
            user.nftTokenIds,
            //getUserDebt(userAddress), //c this was what was originally there but this is wrong as getuserdebt gets the actual debt which takes interest into account and not the scaled debt balance
            user.scaledDebtBalance,
            getUserCollateralValue(userAddress),
            isUnderLiquidation[userAddress],
            reserve.liquidityIndex,
            reserve.usageIndex,
            reserve.totalLiquidity,
            reserve.totalUsage
        );
    }

    // ADMIN FUNCTIONS

    /**
     * @notice Pauses the contract functions under `whenNotPaused`
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract functions under `whenNotPaused`
     * @dev Only callable by the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Sets the prime rate of the reserve
     * @param newPrimeRate The new prime rate (in RAY)
     */
    function setPrimeRate(uint256 newPrimeRate) external onlyPrimeRateOracle {
        ReserveLibrary.setPrimeRate(reserve, rateData, newPrimeRate);
    }

    /**
     * @notice Sets the address of the price oracle
     * @param newOracle The new price oracle address
     */
    function setPrimeRateOracle(address newOracle) external onlyOwner {
        primeRateOracle = newOracle;
    }

    /**
     * @notice Sets the protocol fee rate
     * @param newProtocolFeeRate The new protocol fee rate (in RAY)
     */
    function setProtocolFeeRate(uint256 newProtocolFeeRate) external onlyOwner {
        rateData.protocolFeeRate = newProtocolFeeRate;
    }

    /**
     * @notice Sets the address of the Curve crvUSD vault
     * @param newVault The address of the new Curve vault contract
     */
    function setCurveVault(address newVault) external onlyOwner {
        require(newVault != address(0), "Invalid vault address");
        address oldVault = address(curveVault);
        curveVault = ICurveCrvUSDVault(newVault);
        emit CurveVaultUpdated(oldVault, newVault);
    }

    /**
     * @notice Sets the address of the Stability Pool
     * @dev Only callable by the contract owner
     * @param newStabilityPool The address of the new Stability Pool
     */
    function setStabilityPool(address newStabilityPool) external onlyOwner {
        if (newStabilityPool == address(0)) revert AddressCannotBeZero();
        if (newStabilityPool == stabilityPool) revert SameAddressNotAllowed();

        address oldStabilityPool = stabilityPool;
        stabilityPool = newStabilityPool;

        emit StabilityPoolUpdated(oldStabilityPool, newStabilityPool);
    }

    /**
     * @notice Rescue tokens mistakenly sent to this contract
     * @dev Only callable by the contract owner
     * @param tokenAddress The address of the ERC20 token
     * @param recipient The address to send the rescued tokens to
     * @param amount The amount of tokens to rescue
     */
    function rescueToken(
        address tokenAddress, //c a1: assumes that any token can be rescued. If this token is an erc721 or erc777 or cusdv3, this could be a problem which leads to the second and third assumption issues
        address recipient, //c a2: assumes that the recipient is a valid address. If the recipient is a contract that does not accept the token, the token will be lost forever. ez DOS but can i escalate ???
        uint256 amount //c assumes that amount is always valid. if token is cusdv3 is entered and TYPE(UINT256).MAX is entered, it will send the full amount of the lending pool contract
    ) external onlyOwner {
        require(
            tokenAddress != reserve.reserveRTokenAddress,
            "Cannot rescue RToken"
        ); //bug can cause DOS here but wont be a high or reenter the function here and the only thing not updated is the state so with state not updated, is there anything i can do to cause an issue????
        IERC20(tokenAddress).safeTransfer(recipient, amount);
    }

    /**
     * @notice Transfers accrued dust (small amounts of tokens) to a specified recipient
     * @dev This function can only be called by the contract owner
     * @param recipient The address to receive the accrued dust
     * @param amount The amount of dust to transfer
     */
    function transferAccruedDust(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        // update state
        ReserveLibrary.updateReserveState(reserve, rateData);

        require(
            recipient != address(0),
            "LendingPool: Recipient cannot be zero address"
        );
        IRToken(reserve.reserveRTokenAddress).transferAccruedDust(
            recipient,
            amount
        );
    }

    /**
     * @notice Internal function to ensure sufficient liquidity is available for withdrawals or borrowing
     * @param amount The amount required
     */
    function _ensureLiquidity(uint256 amount) internal {
        // if curve vault is not set, do nothing
        if (address(curveVault) == address(0)) {
            return;
        }

        uint256 availableLiquidity = IERC20(reserve.reserveAssetAddress)
            .balanceOf(reserve.reserveRTokenAddress);

        if (availableLiquidity < amount) {
            uint256 requiredAmount = amount - availableLiquidity;
            // Withdraw required amount from the Curve vault
            _withdrawFromVault(requiredAmount);
        }
    }

    /**
     * @notice Rebalances liquidity between the buffer and the Curve vault to maintain the desired buffer ratio
     */
    function _rebalanceLiquidity() internal {
        //c this function sets a liquidity buffer ratio which is what determines whether RAAC should deposit excess liquidity to a curve vault to get rewards or not.  so it sets a buffer ratio and if the total available liquidity is greater than the buffer they should have, they depsoit the excess into curve vault which is simply a crvUSD valut where users can deposit assets and gain rewards. if the total available liquidity is less than the buffer they should have, they withdraw the shortage from the curve vault. this is what this function does

        //q is there a way to stop withdrawals from happening in curve?? need to look at the curve vault contract to see if this is possible
        // if curve vault is not set, do nothing
        if (address(curveVault) == address(0)) {
            return;
        }

        uint256 totalDeposits = reserve.totalLiquidity; // Total liquidity in the system
        //c this makes sense because this is the total active liquidity in the protocol which is the liquidity less the borrows
        uint256 desiredBuffer = totalDeposits.percentMul(liquidityBufferRatio);

        uint256 currentBuffer = IERC20(reserve.reserveAssetAddress).balanceOf(
            reserve.reserveRTokenAddress
        );
        //c so i had an idea that current buffer is always going to be greater than desired buffer because totalDeposits and balanceOf the reserveRTokenAddress are the same but that was wrong because that will only be the case the first time this function is called. once this function is called the first time, current buffer will always be greater than desired buffer which *should* transfer tokens from rtoken to curve vault. once this transfer happens, the rtoken asset balance will be less than the total deposits. This will keep happening until rtoken balance less than 20% of total available liquidity which is totaldeposits. once this happens, the protocol is deemed not to have enough liquidity and the protocol will withdraw from the curve vault. this is the idea behind this function

        if (currentBuffer > desiredBuffer) {
            uint256 excess = currentBuffer - desiredBuffer;
            // Deposit excess into the Curve vault
            _depositIntoVault(excess);
        } else if (currentBuffer < desiredBuffer) {
            uint256 shortage = desiredBuffer - currentBuffer;
            // Withdraw shortage from the Curve vault
            _withdrawFromVault(shortage); //c  here is the vault contract you can have a look at https://github.com/curvefi/scrvusd/blob/main/contracts/yearn/VaultV3.vy . check this to see if there is a way to stop withdrawals just like zero shares stop depsoits which i raised in the _depositIntoVault function
        }

        emit LiquidityRebalanced(currentBuffer, totalVaultDeposits);
    }

    /**
     * @notice Internal function to deposit liquidity into the Curve vault
     * @param amount The amount to deposit
     */
    function _depositIntoVault(uint256 amount) internal {
        IERC20(reserve.reserveAssetAddress).approve(
            address(curveVault),
            amount
        );
        curveVault.deposit(amount, address(this));
        totalVaultDeposits += amount;
        //bug REPORTED the amount being sent here is supposed to come from the rtoken as that is where the assets are. if this is not done, the contract will not have enough funds to deposit into the curve vault so it will revert. this is a bug
    }

    /**
     * @notice Internal function to withdraw liquidity from the Curve vault
     * @param amount The amount to withdraw
     */
    function _withdrawFromVault(uint256 amount) internal {
        curveVault.withdraw(
            amount,
            address(this),
            msg.sender,
            0, //bug REPORTED could this max_loss cause an unnecessary revert leading to DOS ??
            new address[](0)
        );
        totalVaultDeposits -= amount;
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
    ) public pure returns (uint256) {
        //c should be internal but I changed for testing purposes
        if (totalLiquidity < 1) {
            return WadRayMath.RAY;
        }
        uint256 utilizationRate = totalDebt
            .rayDiv(totalLiquidity + totalDebt)
            .toUint128();
        return utilizationRate;
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
    ) public returns (uint256) {
        if (totalDebt < 1) {
            return 0;
        }

        grossLiquidityRate = utilizationRate.rayMul(usageRate);
        protocolFeeAmount = grossLiquidityRate.rayMul(protocolFeeRate);
        uint256 netLiquidityRate = grossLiquidityRate - protocolFeeAmount; //bug there is going to be an obvious underflow here because if the protocol fee rate is greater than the gross liquidity rate, then the net liquidity rate will be negative.

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
    ) public pure returns (uint256) {
        //c for testing purposes, I made this function public

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

            uint256 rateIncrease = utilizationRate.rayMul(rateSlope).rayDiv(
                optimalUtilizationRate
            );

            rate = baseRate + rateIncrease;
        } else {
            uint256 excessUtilization = utilizationRate -
                optimalUtilizationRate;

            uint256 maxExcessUtilization = WadRayMath.RAY -
                optimalUtilizationRate;
            uint256 rateSlope = maxRate - primeRate;
            uint256 rateIncrease = excessUtilization.rayMul(rateSlope).rayDiv(
                maxExcessUtilization
            );

            rate = primeRate + rateIncrease;
        }
        return rate;
    }
}
