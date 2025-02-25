// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../libraries/math/WadRayMath.sol";
import "../../interfaces/core/tokens/IDebtToken.sol";
import "../../interfaces/core/pools/LendingPool/ILendingPool.sol";

/**
 * @title DebtToken
 * @notice Implementation of the debt token for the RAAC lending protocol.
 *         Users accumulate debt over time due to interest accrual, represented by the usage index.
 * @dev This contract aligns with Aave's VariableDebtToken implementation, scaling balances by the usage index.
 */
contract DebtToken is ERC20, ERC20Permit, IDebtToken, Ownable {
    using WadRayMath for uint256;
    using SafeCast for uint256;

    // Address of the Reserve Pool contract
    address private _reservePool;

    // Usage index, represents cumulative interest
    uint256 private _usageIndex;

    // Dust threshold for debt balances
    uint256 private constant DUST_THRESHOLD = 1e4;

    struct UserState {
        uint128 index;
    }

    mapping(address => UserState) private _userState;

    // EVENTS

    /**
     * @notice Emitted when the Reserve Pool address is updated
     * @param oldReservePool The old Reserve Pool address
     * @param newReservePool The new Reserve Pool address
     */
    event ReservePoolUpdated(
        address indexed oldReservePool,
        address indexed newReservePool
    );

    /**
     * @notice Emitted when the usage index is updated
     * @param newUsageIndex The new usage index
     */
    event UsageIndexUpdated(uint256 newUsageIndex);

    /**
     * @notice Emitted when debt tokens are minted
     * @param caller The address initiating the mint
     * @param onBehalfOf The recipient of the debt tokens
     * @param amount The amount minted (in underlying asset units)
     * @param balanceIncrease The increase in the user's debt balance
     * @param index The usage index at the time of minting
     */
    event Mint(
        address indexed caller,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 balanceIncrease,
        uint256 index
    );

    /**
     * @notice Emitted when debt tokens are burned
     * @param from The address from which tokens are burned
     * @param amount The amount burned (in underlying asset units)
     * @param index The usage index at the time of burning
     */
    event Burn(address indexed from, uint256 amount, uint256 index);

    // CUSTOM ERRORS

    error OnlyReservePool();
    error InvalidAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error TransfersNotAllowed();

    // MODIFIERS

    /**
     * @dev Ensures that only the Reserve Pool can call the function
     */
    modifier onlyReservePool() {
        if (msg.sender != _reservePool) revert OnlyReservePool();
        _;
    }

    // CONSTRUCTOR

    /**
     * @dev Initializes the DebtToken contract with the given parameters
     * @param name The name of the token
     * @param symbol The symbol of the token
     */

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert InvalidAddress();
        _usageIndex = uint128(WadRayMath.RAY);
    }

    // EXTERNAL FUNCTIONS

    /**
     * @notice Sets the Reserve Pool address
     * @param newReservePool The address of the Reserve Pool
     */
    function setReservePool(address newReservePool) external onlyOwner {
        if (newReservePool == address(0)) revert InvalidAddress();
        address oldReservePool = _reservePool;
        _reservePool = newReservePool;
        emit ReservePoolUpdated(oldReservePool, newReservePool);
    }

    /**
     * @notice Updates the usage index
     * @param newUsageIndex The new usage index
     */
    function updateUsageIndex(
        uint256 newUsageIndex
    ) external override onlyReservePool {
        if (newUsageIndex < _usageIndex) revert InvalidAmount();
        _usageIndex = newUsageIndex;
        emit UsageIndexUpdated(newUsageIndex);
    }

    /**
     * @notice Mints debt tokens to a user
     * @param user The address initiating the mint
     * @param onBehalfOf The recipient of the debt tokens
     * @param amount The amount to mint (in underlying asset units)
     * @param index The usage index at the time of minting
     * @return A tuple containing:
     *         - bool: True if the previous balance was zero
     *         - uint256: The amount of scaled tokens minted
     *         - uint256: The new total supply after minting
     */
    function mint(
        address user,
        address onBehalfOf,
        uint256 amount,
        uint256 index
    ) external override onlyReservePool returns (bool, uint256, uint256) {
        if (user == address(0) || onBehalfOf == address(0))
            revert InvalidAddress();
        if (amount == 0) {
            return (false, 0, totalSupply());
        }

        uint256 amountScaled = amount.rayDiv(index);
        if (amountScaled == 0) revert InvalidAmount();

        uint256 scaledBalance = balanceOf(onBehalfOf); //c this returns the actual debt of the user
        bool isFirstMint = scaledBalance == 0;

        uint256 balanceIncrease = 0;
        if (
            _userState[onBehalfOf].index != 0 &&
            _userState[onBehalfOf].index < index
        ) {
            balanceIncrease =
                scaledBalance.rayMul(index) -
                scaledBalance.rayMul(_userState[onBehalfOf].index);
        } //q this subtraction to get the balance increase is supposed to get the amount of interest the user has accumulated since their last borrow and adds that increase to the next debt token they want to borrow below. why is this done because when i am repaying

        //bug this is wrong and inflates the user's debt. scaledBalance is the actual debt of the user which is what the balanceOf function does. to calculate the balance increase, they then multiply the actual debt again by index and subtract the actual debt multiplied by the user's previous index. This is wrong because the actual debt of the user is already scaled by the index so multiplying it by the index again is wrong. the correct way is to get the scaled user debt from the userdata struct and multiply that by the index and subtract the scaled user debt by the user's previous index. This is the correct way to get the balance increase. let me explain with an example. if my actual debt is 5 and old index = 1 and new index =2 but my normalized debt from when i borrowed is 4. the balance increase should be 4*2 - 4*1 = 4. but the current implementation does 5*2 - 5*1 = 5 which is wrong. the effect of this is that if a user attempts to pay back their whole debt or what they think their whole debt should be, there will be a dust amount of debt left which is incorrect. this issue is further compounded because when a user deposits assets into the protocol, Rtoken::mint is called and the balanceincrease is not added to the amount like is done here which is further proof that this is wrong.
        _userState[onBehalfOf].index = index.toUint128();

        uint256 amountToMint = amount + balanceIncrease; //q what is the point of this line ??

        _mint(onBehalfOf, amountToMint.toUint128());

        emit Transfer(address(0), onBehalfOf, amountToMint);
        emit Mint(user, onBehalfOf, amountToMint, balanceIncrease, index);

        return (scaledBalance == 0, amountToMint, totalSupply());
    }

    /**
     * @notice Burns debt tokens from a user
     * @param from The address from which tokens are burned
     * @param amount The amount to burn (in underlying asset units)
     * @param index The usage index at the time of burning
     * @return A tuple containing:
     *         - uint256: The amount of scaled tokens burned
     *         - uint256: The new total supply after burning
     *         - uint256: The amount of underlying tokens burned
     *         - uint256: The balance increase due to interest
     */
    function burn(
        address from,
        uint256 amount,
        uint256 index
    )
        external
        override
        onlyReservePool
        returns (uint256, uint256, uint256, uint256)
    {
        if (from == address(0)) revert InvalidAddress();
        if (amount == 0) {
            return (0, totalSupply(), 0, 0);
        }

        uint256 userBalance = balanceOf(from);

        uint256 balanceIncrease = 0;
        if (_userState[from].index != 0 && _userState[from].index < index) {
            uint256 borrowIndex = ILendingPool(_reservePool)
                .getNormalizedDebt(); //c getnormalizeddebt is used here but this isnt outdated because ReserveLibrary.updateReserveState is called pretty much everytime this function is called but will update if i find where this isnt the case but so far, this doesnt look dangerous
            balanceIncrease =
                userBalance.rayMul(borrowIndex) -
                userBalance.rayMul(_userState[from].index);
            amount = amount;
        }

        _userState[from].index = index.toUint128();

        if (amount > userBalance) {
            amount = userBalance;
        } //c this check is supposed to make sure that a user cannot burn more debt than their debt balance * current usage index . the balanceOf function multiplies the user's debt balance(which is their normalized debt as i explained in the balanceOf function) by the current usage index so this check is to make sure that the user cannot burn more debt than they have borrowed.

        uint256 amountScaled = amount.rayDiv(index);

        //c you might want to argue that after this division the user is left with dust amount as scaleduserdebt but as you know, in solidity, it almost always rounds down so any remainder of 0.whatever is going to 0 and I saw this when testing that once a user is liquidated, their scaleddebtbalance always resets to 0 which is expected behaviour.

        if (amountScaled == 0) revert InvalidAmount();

        _burn(from, amount.toUint128());
        emit Burn(from, amountScaled, index);

        return (amount, totalSupply(), amountScaled, balanceIncrease);
    }

    // VIEW FUNCTIONS

    /**
     * @notice Returns the scaled debt balance of the user
     * @param account The address of the user
     * @return The user's debt balance (scaled by the usage index)
     */
    function balanceOf(
        address account
    ) public view override(ERC20, IERC20) returns (uint256) {
        uint256 scaledBalance = super.balanceOf(account);
        return
            scaledBalance.rayMul(
                ILendingPool(_reservePool).getNormalizedDebt()
            ); //c same deal here. this balanceof function is called in the burn function but as I said in the burn function, whenever that function is called ReserveLibrary.updateReserveState is called before which updates the usage index so it is not stale.

        //c worth noting that the balanceOf function gets the balance of the debt token of the user and multiplies it by the current usage index as a safety check in the burn function. Note that in the mint function, which as we know, calls _update. _update from a normal ERC20 contract is overriden in this contract for 2 reasons. The first is to make sure the debt cannot be transferred to another address. The second is that whenever a user mints, they are minted the normalized debt. They arent minted the actual amount of debt tokens 1:1 to what they borrowed. You can see this in the _update function in this contract as well as LendingPool::borrow. This is why this function makes sense because by multiplying the balance of the user which is the normalized debt by the usage index, they get the actual debt of the user. This is why the balance of the user is multiplied by the usage index in the burn function to make sure that the user cannot burn more debt than they have borrowed.
    }

    /**
     * @notice Returns the scaled total supply
     * @return The total supply (scaled by the usage index)
     */
    function totalSupply()
        public
        view
        override(ERC20, IERC20)
        returns (uint256)
    {
        uint256 scaledSupply = super.totalSupply();
        return
            scaledSupply.rayDiv(ILendingPool(_reservePool).getNormalizedDebt());
    } //bug REPORTED the totalsupply should be multiplied by the usage index not divided by it. see totalSupply in rtoken.sol

    /**
     * @notice Returns the usage index
     * @return The usage index
     */
    function getUsageIndex() external view override returns (uint256) {
        return _usageIndex;
    }

    /**
     * @notice Returns the Reserve Pool address
     * @return The Reserve Pool address
     */
    function getReservePool() external view returns (address) {
        return _reservePool;
    }

    // INTERNAL FUNCTIONS

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        if (from != address(0) && to != address(0)) {
            revert TransfersNotAllowed(); // Only allow minting and burning
        }

        uint256 scaledAmount = amount.rayDiv(
            ILendingPool(_reservePool).getNormalizedDebt()
        );
        super._update(from, to, scaledAmount);
        emit Transfer(from, to, amount);
    }

    // ERC20 OVERRIDES

    /**
     * @notice Returns the non-scaled balance of the user
     * @param user The address of the user
     * @return The user's non-scaled balance
     */
    function scaledBalanceOf(address user) external view returns (uint256) {
        return super.balanceOf(user);
    }

    /**
     * @notice Returns the non-scaled total supply
     * @return The non-scaled total supply
     */
    function scaledTotalSupply() external view returns (uint256) {
        return super.totalSupply();
    }
}
