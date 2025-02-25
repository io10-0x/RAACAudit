// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../../libraries/math/WadRayMath.sol";

import "../../../interfaces/core/pools/StabilityPool/IStabilityPool.sol";
import "../../../interfaces/core/pools/LendingPool/ILendingPool.sol";
import "../../../interfaces/core/minters/RAACMinter/IRAACMinter.sol";
import "../../../interfaces/core/tokens/IRAACToken.sol";
import "../../../interfaces/core/tokens/IRToken.sol";
import "../../../interfaces/core/tokens/IDEToken.sol";

contract StabilityPool is
    IStabilityPool,
    Initializable,
    ReentrancyGuard,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IRToken;
    using SafeERC20 for IDEToken;
    using SafeERC20 for IRAACToken;

    // State variables
    IRToken public rToken;
    IDEToken public deToken;
    IRAACToken public raacToken;
    ILendingPool public lendingPool;
    IERC20 public crvUSDToken;

    // Manager variables (manger can liquidate as stability pool)
    mapping(address => bool) public managers;
    // Manager value allocation / allowance
    mapping(address => uint256) public managerAllocation;
    uint256 public totalAllocation;
    address[] public managerList;

    mapping(address => uint256) public userDeposits;

    IRAACMinter public raacMinter;
    address public liquidityPool;

    mapping(address => bool) public supportedMarkets;
    mapping(address => uint256) public marketAllocations;

    uint256 public lastUpdate;
    uint256 public index = 1e18;

    address private immutable _initialOwner;

    // Allow to make rToken / deToken decimals flexible
    uint8 public rTokenDecimals;
    uint8 public deTokenDecimals;

    // Constructor
    constructor(address initialOwner) {
        _initialOwner = initialOwner;
    }

    /**
     * @notice Initializes the StabilityPool contract.
     * @param _rToken Address of the RToken contract.
     * @param _deToken Address of the DEToken contract.
     * @param _raacToken Address of the RAAC token contract.
     * @param _raacMinter Address of the RAACMinter contract.
     */
    function initialize(
        address _rToken,
        address _deToken,
        address _raacToken,
        address _raacMinter,
        address _crvUSDToken,
        address _lendingPool
    ) public initializer {
        if (
            _rToken == address(0) ||
            _deToken == address(0) ||
            _raacToken == address(0) ||
            _raacMinter == address(0) ||
            _crvUSDToken == address(0) ||
            _lendingPool == address(0)
        ) revert InvalidAddress();
        __Ownable_init(_initialOwner);
        __Pausable_init();
        rToken = IRToken(_rToken);
        deToken = IDEToken(_deToken);
        raacToken = IRAACToken(_raacToken);
        raacMinter = IRAACMinter(_raacMinter);
        crvUSDToken = IERC20(_crvUSDToken);
        lendingPool = ILendingPool(_lendingPool);

        // Get and store the decimals
        rTokenDecimals = IRToken(_rToken).decimals();
        deTokenDecimals = IDEToken(_deToken).decimals();
    }

    // Modifiers
    modifier onlyLiquidityPool() {
        if (msg.sender != liquidityPool) revert UnauthorizedAccess();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlyManager() {
        if (!managers[msg.sender]) revert UnauthorizedAccess();
        _;
    }

    modifier onlyManagerOrOwner() {
        if (!managers[msg.sender] && msg.sender != owner())
            revert UnauthorizedAccess();
        _;
    }

    /**
     * @notice Adds a new manager with a specified allocation.
     * @param manager Address of the manager to add.
     * @param allocation Allocation amount for the manager.
     */
    function addManager(
        address manager,
        uint256 allocation
    ) external onlyOwner validAmount(allocation) {
        if (managers[manager]) revert ManagerAlreadyExists();
        managers[manager] = true;
        managerAllocation[manager] = allocation;
        totalAllocation += allocation;
        managerList.push(manager);
        emit ManagerAdded(manager, allocation);
    }

    /**
     * @notice Removes an existing manager.
     * @param manager Address of the manager to remove.
     */
    function removeManager(address manager) external onlyOwner {
        if (!managers[manager]) revert ManagerNotFound();
        totalAllocation -= managerAllocation[manager];
        delete managerAllocation[manager];
        managers[manager] = false;
        _removeManagerFromList(manager);
        emit ManagerRemoved(manager);
    }

    /**
     * @notice Updates the allocation for an existing manager.
     * @param manager Address of the manager.
     * @param newAllocation New allocation amount.
     */
    function updateAllocation(
        address manager,
        uint256 newAllocation
    ) external onlyOwner validAmount(newAllocation) {
        if (!managers[manager]) revert ManagerNotFound();
        totalAllocation =
            totalAllocation -
            managerAllocation[manager] +
            newAllocation;
        managerAllocation[manager] = newAllocation;
        emit AllocationUpdated(manager, newAllocation);
    }

    /**
     * @notice Sets the RAACMinter contract address.
     * @param _raacMinter Address of the new RAACMinter contract.
     */
    function setRAACMinter(address _raacMinter) external onlyOwner {
        raacMinter = IRAACMinter(_raacMinter);
    }

    /**
     * @dev Internal function to mint RAAC rewards.
     */
    function _mintRAACRewards() internal {
        if (address(raacMinter) != address(0)) {
            raacMinter.tick();
        }
    }

    /**
     * @notice Allows a user to deposit rToken and receive deToken.
     * @param amount Amount of rToken to deposit.
     */
    function deposit(
        //c this detoken is different from the debt token in the lending pool. this is a different token. it is supposed to be a 1:1 representation of the rtoken deposited.

        //c looking at DEtoken.sol, all the transfer functions are restricted to the stability pool which has no functions that ever call transfer so as it stands, there is no way to transfer DE tokens. NEED TO ASK ABOUT THIS
        uint256 amount
    ) external nonReentrant whenNotPaused validAmount(amount) {
        //c a1 valid amount modifier assumes 0 is the only invalid amount. NEED TO TEST DIFFERENT DEPOSIT AMOUNTS AND OBSERVE THE BEHAVIOUR
        _update();
        rToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 deCRVUSDAmount = calculateDeCRVUSDAmount(amount);
        deToken.mint(msg.sender, deCRVUSDAmount); //c doesnt follow CEI methodology and even though it has nonReentrant modifier, i can probably perform cross function / cross contract reentrancy. NEED TO LOOK INTO THIS

        userDeposits[msg.sender] += amount;
        _mintRAACRewards(); //q is there any reason why raac rewards are minted twice ?? I have looked at what this function does and it doesnt seem to me like there should be any valid reason for this to be happening because this secodn call wont actually do anything because it is in the same transaction, the block.timestamp will be the same and so will the block.number which are the 2 key factors that determine whether anything happens in this function.

        emit Deposit(msg.sender, amount, deCRVUSDAmount);
    }

    /**
     * @notice Calculates the amount of deToken to mint for a given rToken deposit.
     * @param rcrvUSDAmount Amount of rToken deposited.
     * @return Amount of deToken to mint.
     */
    function calculateDeCRVUSDAmount(
        uint256 rcrvUSDAmount
    ) public view returns (uint256) {
        uint256 scalingFactor = 10 ** (18 + deTokenDecimals - rTokenDecimals);
        return (rcrvUSDAmount * scalingFactor) / getExchangeRate();

        //c there really is no need for all of this extra math. the idea is to mint rtoken to DE token 1:1 so all they had to do was in stabilitypool::deposit, mint the same amount of rtokens like whats the point of all this because detokendecimals is 18 and so is rtoken decimals so really this is unnecessary math and just welcomes precision loss which i am going to test for actually
    }

    /**
     * @notice Calculates the amount of rToken to return for a given deToken redemption.
     * @param deCRVUSDAmount Amount of deToken to redeem.
     * @return Amount of rToken to return.
     */
    function calculateRcrvUSDAmount(
        uint256 deCRVUSDAmount
    ) public view returns (uint256) {
        uint256 scalingFactor = 10 ** (18 + rTokenDecimals - deTokenDecimals);
        return (deCRVUSDAmount * getExchangeRate()) / scalingFactor;

        //c already spoke on how useless this math is in the calculatedecrvusdamount function
    }

    /**
     * @notice Gets the current exchange rate between rToken and deToken.
     * @return Current exchange rate.
     */
    function getExchangeRate() public view returns (uint256) {
        // uint256 totalDeCRVUSD = deToken.totalSupply();
        // uint256 totalRcrvUSD = rToken.balanceOf(address(this));
        // if (totalDeCRVUSD == 0 || totalRcrvUSD == 0) return 10**18;

        // uint256 scalingFactor = 10**(18 + deTokenDecimals - rTokenDecimals);
        // return (totalRcrvUSD * scalingFactor) / totalDeCRVUSD;
        return 1e18;
    }

    /**
     * @notice Allows a user to withdraw their rToken and RAAC rewards.
     * @param deCRVUSDAmount Amount of deToken to redeem.
     */
    function withdraw(
        uint256 deCRVUSDAmount
    ) external nonReentrant whenNotPaused validAmount(deCRVUSDAmount) {
        //c a1 assumes that 0 is the only invalid amount. can i enter an amount that can cause this revert
        //c on first glance, it looks like the user can only get their RAAC rewards by withdrawing from the stability pool. will edit if something changes in review

        //c so the idea is that once a user deposits rtokens in the stability pool, these tokens no longer accrue interest and are exchanged 1:1 for detokens which make the user eligible for RAAC token rewards
        _update();
        if (deToken.balanceOf(msg.sender) < deCRVUSDAmount)
            revert InsufficientBalance();

        uint256 rcrvUSDAmount = calculateRcrvUSDAmount(deCRVUSDAmount);
        uint256 raacRewards = calculateRaacRewards(msg.sender);
        if (userDeposits[msg.sender] < rcrvUSDAmount)
            revert InsufficientBalance();
        //c so if precision loss causes a slight deviation from this math, it could prevent a user from withdrawing, need to see if this is exploitable

        //bug if a user transfers their de tokens from a compromised EOA for example, this means that the user wont be able to redeem their rtoken and raac rewards even though they own the token. DE tokens can only be transferred by the stability pool which doesnt really make much sense because there is no function in this stability pool that allows for the transfer of DE tokens. NEED TO ASK ABOUT THIS
        userDeposits[msg.sender] -= rcrvUSDAmount;

        if (userDeposits[msg.sender] == 0) {
            delete userDeposits[msg.sender];
        }

        deToken.burn(msg.sender, deCRVUSDAmount);
        rToken.safeTransfer(msg.sender, rcrvUSDAmount);
        if (raacRewards > 0) {
            raacToken.safeTransfer(msg.sender, raacRewards);
        }

        emit Withdraw(msg.sender, rcrvUSDAmount, deCRVUSDAmount, raacRewards);
    }

    /**
     * @notice Calculates the pending RAAC rewards for a user.
     * @param user Address of the user.
     * @return Amount of RAAC rewards.
     */
    function calculateRaacRewards(address user) public view returns (uint256) {
        uint256 userDeposit = userDeposits[user];
        uint256 totalDeposits = deToken.totalSupply();

        //bug REPORTED stepwise jumps can lead to reward front run. if i am watching this protocol and see that raac rewards havent been deposited or withdrawn for a while which are the 2 functions that mint raac rewards, then an attacker can deposit a large amount of rtokens just before a user calls withdraw and then get a large share of their rewards without having to deposit for as long as they have and then can just withdraw after them and get similar/more rewards

        uint256 totalRewards = raacToken.balanceOf(address(this));
        if (totalDeposits < 1e6) return 0;

        return (totalRewards * userDeposit) / totalDeposits; //q possible rounding error here? cant seem to find one. i tried to test this in StabilityPool.test.js but the difference was about 1 wei which is kinda insignificant. see "precision loss checks" in the test file
    }

    /**
     * @notice Gets the pending RAAC rewards for a user.
     * @param user Address of the user.
     * @return Amount of pending RAAC rewards.
     */
    function getPendingRewards(address user) external view returns (uint256) {
        return calculateRaacRewards(user); //bug this is outdated as if blocks have passed since the last update, the rewards will not be up to date. this is a possibly a low and worth bringing up in the audit
    }

    /**
     * @notice Gets the allocation for a manager.
     * @param manager Address of the manager.
     * @return Allocation amount.
     */
    function getManagerAllocation(
        address manager
    ) external view returns (uint256) {
        return managerAllocation[manager];
    }

    /**
     * @notice Gets the total allocation across all managers.
     * @return Total allocation amount.
     */
    function getTotalAllocation() external view returns (uint256) {
        return totalAllocation;
    }

    /**
     * @notice Gets the deposit amount for a user.
     * @param user Address of the user.
     * @return Deposit amount.
     */
    function getUserDeposit(address user) external view returns (uint256) {
        return userDeposits[user];
    }

    /**
     * @notice Checks if an address is a manager.
     * @param manager Address to check.
     * @return True if the address is a manager, false otherwise.
     */
    function getManager(address manager) external view returns (bool) {
        return managers[manager];
    }

    /**
     * @notice Gets the list of all managers.
     * @return Array of manager addresses.
     */
    function getManagers() external view returns (address[] memory) {
        return managerList;
    }

    /**
     * @notice Sets the liquidity pool address.
     * @param _liquidityPool Address of the liquidity pool.
     */
    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        liquidityPool = _liquidityPool;
        emit LiquidityPoolSet(_liquidityPool);
    }

    /**
     * @notice Deposits RAAC tokens from the liquidity pool.
     * @param amount Amount of RAAC tokens to deposit.
     */
    function depositRAACFromPool(
        uint256 amount
    ) external onlyLiquidityPool validAmount(amount) {
        uint256 preBalance = raacToken.balanceOf(address(this));

        raacToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 postBalance = raacToken.balanceOf(address(this));
        if (postBalance != preBalance + amount) revert InvalidTransfer();

        // TODO: Logic for distributing to managers based on allocation

        emit RAACDepositedFromPool(msg.sender, amount);
    }

    /**
     * @notice Finds the index of a manager in the manager list.
     * @param manager Address of the manager.
     * @return Index of the manager.
     */
    function findManagerIndex(address manager) internal view returns (uint256) {
        for (uint256 i = 0; i < managerList.length; i++) {
            if (managerList[i] == manager) {
                return i;
            }
        } //c could maybe be an unbounded for loop that can cause gas griefing BUT the managers list is obviously bounded the number of managers that the owner wants to add so it is safe to assume they arent going to bombard the contract with managers to fcause gas griefing
        revert ManagerNotFound();
    }

    /**
     * @notice Adds a new market with a specified allocation.
     * @param market Address of the market to add.
     * @param allocation Allocation amount for the market.
     */
    function addMarket(
        address market,
        uint256 allocation
    ) external onlyOwner validAmount(allocation) {
        if (supportedMarkets[market]) revert MarketAlreadyExists();
        supportedMarkets[market] = true;
        marketAllocations[market] = allocation;
        totalAllocation += allocation;
        emit MarketAdded(market, allocation);
    }

    /**
     * @notice Removes an existing market.
     * @param market Address of the market to remove.
     */
    function removeMarket(address market) external onlyOwner {
        if (!supportedMarkets[market]) revert MarketNotFound();
        supportedMarkets[market] = false;
        totalAllocation -= marketAllocations[market];
        delete marketAllocations[market];
        emit MarketRemoved(market);
    }

    /**
     * @notice Updates the allocation for an existing market.
     * @param market Address of the market.
     * @param newAllocation New allocation amount.
     */
    function updateMarketAllocation(
        address market,
        uint256 newAllocation
    ) external onlyOwner validAmount(newAllocation) {
        if (!supportedMarkets[market]) revert MarketNotFound();
        totalAllocation =
            totalAllocation -
            marketAllocations[market] +
            newAllocation;
        marketAllocations[market] = newAllocation;
        emit MarketAllocationUpdated(market, newAllocation);
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Gets the total deposits in the pool.
     * @return Total deposits amount.
     */
    function getTotalDeposits() external view returns (uint256) {
        return rToken.balanceOf(address(this));
    } //c similar idea to the debttoken, when rtoken is sent to rtoken contract, the normalized amount is sent so when balanceOf is called, it returns the normalized amount

    //c i was going to raise that people could send rtokens directly to the stability pool and be able to skew this totaldeposits value and be able to mess with emission rate but in reality, the only incentive for anyone to do this would be to deter people from depositing into the stability pool and the only reason they would want to do that is if they want to gain the rewards for themselves but if they do this, they would be messing up the emission rates for themselves which doesnt make sense to do

    /**
     * @notice Gets the balance of a user.
     * @param user Address of the user.
     * @return Deposit amount of the user.
     */
    function balanceOf(address user) external view returns (uint256) {
        return userDeposits[user];
    }

    /**
     * @dev Internal function to remove a manager from the manager list.
     * @param manager Address of the manager to remove.
     */
    function _removeManagerFromList(address manager) private {
        uint256 managerIndex = findManagerIndex(manager);
        uint256 lastIndex = managerList.length - 1;
        if (managerIndex != lastIndex) {
            managerList[managerIndex] = managerList[lastIndex];
        }
        managerList.pop(); //c this seems to work but to avoid issues,  can  easily use an enumerable set instead of having parallel data structures
    }

    /**
     * @dev Internal function to update state variables.
     */
    function _update() internal {
        _mintRAACRewards();
    }

    /**
     * @notice Liquidates a borrower's position.
     * @dev This function can only be called by a manager or the owner when the contract is not paused.
     * @param userAddress The address of the borrower to liquidate.
     * @custom:throws InvalidAmount If the user's debt is zero.
     * @custom:throws InsufficientBalance If the Stability Pool doesn't have enough crvUSD to cover the debt.
     * @custom:throws ApprovalFailed If the approval of crvUSD transfer to LendingPool fails.
     * @custom:emits BorrowerLiquidated when the liquidation is successful.
     */
    function liquidateBorrower(
        address userAddress
    ) external onlyManagerOrOwner nonReentrant whenNotPaused {
        _update();

        // Get the user's debt from the LendingPool.
        uint256 userDebt = lendingPool.getUserDebt(userAddress);
        //c a1: assumes that the user debt is correctly calculated by the lending pool. this checks out
        uint256 scaledUserDebt = WadRayMath.rayMul(
            userDebt,
            lendingPool.getNormalizedDebt()
        );
        //bug REPORTED the line above multiplies the user debt by the normalized debt (usage index) twice. LendingPool::getUserDebt already multiplies the normalized user debt by the usage index which gives us the actual debt of the user and accounts for interest accrued so this line above just messes up a lot of things

        //c assumes the raymul calculation is correct and correctly multiplies the user debt by the normalized debt without precision issues. THIS CAN BE EXPLORED MORE but so far it seems to be correct

        if (userDebt == 0) revert InvalidAmount();

        uint256 crvUSDBalance = crvUSDToken.balanceOf(address(this));
        if (crvUSDBalance < scaledUserDebt) revert InsufficientBalance();
        /*bug REPORTED in LendingPool::finalizeLiquidation, which this function calls below,  it contains the following line:

         // Transfer reserve assets from Stability Pool to cover the debt
        IERC20(reserve.reserveAssetAddress).safeTransferFrom(
            msg.sender,
            reserve.reserveRTokenAddress,
            amountScaled
        );

        so it transfer's whatever the reserve asset is from LendingPool.sol from this stability pool to the reserveRTokenAddress which is the Rtoken contract. If the reserveassetaddress is not crvUSD, then the above check for the crvUSDbalance is irrelevant and the liquidation will revert which we don't want. 

        This would be ok if the reserve asset was always crvUSD but it may not always be. This is the word from the devs from question i asked in a private thread. 

    That said, we hope to be able to reuse the exact same contract for most of other erc20 (those with custom logics would draw a modified lending pool contract to do that, but all the "classic" erc20 should fit in the pool). So for the pool, still a crvUSD at launch yes, but the same pool is supposed to be reused for other stables. 

    So they intend to use this same lending pool logic for other stablecoins in the future and there is no mention of using a different stability pool. This is a big risk because if the reserve asset is not crvUSD, then the liquidation will revert and the user will not be liquidated. So, reserve.reserveAssetAddress can be any stablecoin address and if it is not crvUSD, then the liquidation will revert. This is a big risk and should be fixed.

    to fix this, you should have a getter function in the lending pool to get what the reserve asset address is and return it. so in this function, the stability pool can call this getter function to get whatever the reserve asset address is and then check the stability pool's balance of that asset and then check if it is greater than the scaled user debt. if it is, then the liquidation can proceed. if it is not, then the liquidation should revert. this is the fix for this bug.
        
        */

        //c There is nowhere in the stability pool where the crvUSD token is sent to the stability pool so where does the crvUSD token come from? This is what the devs said It will be RAAC to provide crvUSD since it will be purchasing the liquidated NFTs off and clear the debt in the system

        // Approve the LendingPool to transfer the debt amount
        bool approveSuccess = crvUSDToken.approve(
            address(lendingPool),
            scaledUserDebt
        );
        //c a3: assumes that the approve function works as expected and there are no weird approve functions that dont allow partial allowances like usdt. I have looked at the crvusd contract at https://etherscan.io/address/0xf939e0a03fb07f59a73314e73794be0e57ac1b4e#code and it doesnt look like theres many issues with this
        if (!approveSuccess) revert ApprovalFailed();
        // Update lending pool state before liquidation
        lendingPool.updateState();
        //c a4: assumes that the approve function in crvusd returns true and it does so this checks out

        // Call finalizeLiquidation on LendingPool
        lendingPool.finalizeLiquidation(userAddress);

        emit BorrowerLiquidated(userAddress, scaledUserDebt);
    }
}
