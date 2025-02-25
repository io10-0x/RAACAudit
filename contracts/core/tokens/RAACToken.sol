// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../libraries/math/PercentageMath.sol";
import "../../interfaces/core/tokens/IRAACToken.sol";

/**
 * @title RAACToken
 * @notice Implementation of the RAAC token with tax mechanisms and whitelisting
 * @dev This contract implements swap and burn taxes, whitelisting, and uses WadRayMath and PercentageMath libraries
 */
contract RAACToken is ERC20, Ownable, IRAACToken {
    using PercentageMath for uint256;

    uint256 public swapTaxRate = 100; // 1% swap tax (100 basis points)
    uint256 public burnTaxRate = 50; // 0.5% burn tax (50 basis points)
    address public feeCollector;
    address public minter;

    uint256 public constant MAX_TAX_RATE = 1000; // 10%
    uint256 public constant BASE_INCREMENT_LIMIT = 1000; // 10% in basis points
    uint256 public taxRateIncrementLimit = BASE_INCREMENT_LIMIT;

    uint256 public expectedburnamount; //c for testing purposes
    uint256 public taxAmount; //c for testing purposes
    bool public check; //c for testing purposes
    uint256 public totalTax; //c for testing purposes
    uint256 public burnAmount; //c for testing purposes
    uint256 public swapfee; //c for testing purposes

    mapping(address => bool) public whitelistAddress;

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinterCanMint();
        _;
    }

    /**
     * @dev Constructor that initializes the RAAC token
     * @param initialOwner The address of the initial owner
     * @param initialSwapTaxRate The initial swap tax rate (in basis points)
     * @param initialBurnTaxRate The initial burn tax rate (in basis points)
     */
    constructor(
        address initialOwner,
        uint256 initialSwapTaxRate,
        uint256 initialBurnTaxRate
    ) ERC20("RAAC Token", "RAAC") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert InvalidAddress();
        feeCollector = initialOwner;

        if (initialSwapTaxRate > MAX_TAX_RATE) revert SwapTaxRateExceedsLimit();
        swapTaxRate = initialSwapTaxRate == 0 ? 100 : initialSwapTaxRate; // default to 1% if 0
        emit SwapTaxRateUpdated(swapTaxRate);

        if (initialBurnTaxRate > MAX_TAX_RATE) revert BurnTaxRateExceedsLimit();
        burnTaxRate = initialBurnTaxRate == 0 ? 50 : initialBurnTaxRate; // default to 0.5% if 0
        emit BurnTaxRateUpdated(burnTaxRate);
    }

    /**
     * @dev Sets the minter address
     * @param _minter The address of the new minter
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert InvalidAddress();
        minter = _minter;
        emit MinterSet(_minter);
    }

    /**
     * @dev Mints new tokens
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (to == address(0)) revert InvalidAddress();
        _mint(to, amount);
    } //c standard minting mechanism

    /**
     * @dev Burns tokens from the caller's balance
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external {
        taxAmount = amount.percentMul(burnTaxRate);
        _burn(msg.sender, amount - taxAmount); //c if a whitelisted address calls this function, they will still be taxed but in the documentation it says the the RAACToken purpose is to Provide whitelisting functionality for tax-free transfers and it says transfers and not burns so we can safely ignore this i guess
        expectedburnamount = amount - taxAmount; //c for testing purposes

        //c so amount - taxAmount is the amount that will be burnt and taxAmount is the amount that will be sent to the fee collector AFTER _burn has happened

        //bug REPORTED this function calls transfer and if a non whitelisted address calls this function, the amount that the fee collector gets will be less than taxAmount

        if (taxAmount > 0 && feeCollector != address(0)) {
            _transfer(msg.sender, feeCollector, taxAmount); //bug shouldnt be fee be prioritized over burn? if tax amount is not equal to amount - tax amount, due to some precision loss, then burn will fail
        } //c burn tax mechanism there are taxes on burns but not mints, interesting
    }

    /**
     * @dev Sets the fee collector address
     * @param _feeCollector The address of the new fee collector
     */
    function setFeeCollector(address _feeCollector) external onlyOwner {
        // Fee collector can be set to zero address to disable fee collection
        if (feeCollector == address(0) && _feeCollector != address(0)) {
            emit FeeCollectionEnabled(_feeCollector);
        }
        if (_feeCollector == address(0)) {
            emit FeeCollectionDisabled();
        }

        feeCollector = _feeCollector;
        emit FeeCollectorSet(_feeCollector);
    }

    /**
     * @dev Sets the swap tax rate
     * @param rate The new swap tax rate (in basis points)
     */
    function setSwapTaxRate(uint256 rate) external onlyOwner {
        _setTaxRate(rate, true);
    }

    /**
     * @dev Sets the burn tax rate
     * @param rate The new burn tax rate (in basis points)
     */
    function setBurnTaxRate(uint256 rate) external onlyOwner {
        _setTaxRate(rate, false);
    }

    function _setTaxRate(uint256 newRate, bool isSwapTax) private {
        if (newRate > MAX_TAX_RATE) revert TaxRateExceedsLimit();

        uint256 currentRate = isSwapTax ? swapTaxRate : burnTaxRate;

        if (currentRate != 0) {
            uint256 maxChange = currentRate.percentMul(taxRateIncrementLimit);
            // Check if the new rate is too high (newRate > currentRate + maxChange) or too low (newRate < currentRate && currentRate - newRate > maxChange) by more than the allowed increment
            bool isTooHighOrTooLow = newRate > currentRate + maxChange ||
                (newRate < currentRate && currentRate - newRate > maxChange); //c couldve just said if newRate > currentRate + maxChange || newRate < currentRate - maxChange but ok

            if (isTooHighOrTooLow) {
                revert TaxRateChangeExceedsAllowedIncrement();
            }
        }

        if (isSwapTax) {
            swapTaxRate = newRate;
            emit SwapTaxRateUpdated(newRate);
        } else {
            burnTaxRate = newRate;
            emit BurnTaxRateUpdated(newRate);
        } //c this checks out but assumption analysis not done yet
    }

    /**
     * @dev Sets the tax rate increment limit
     * @param limit The new increment limit (in basis points)
     */
    function setTaxRateIncrementLimit(uint256 limit) external onlyOwner {
        if (limit > BASE_INCREMENT_LIMIT)
            revert IncrementLimitExceedsBaseLimit();
        taxRateIncrementLimit = limit;
        emit TaxRateIncrementLimitUpdated(limit);
    }

    /**
     * @dev Adds or removes an address from the whitelist
     * @param account The address to manage in the whitelist
     * @param add A boolean indicating whether to add or remove the address
     */
    function manageWhitelist(address account, bool add) external onlyOwner {
        if (add) {
            if (account == address(0)) revert CannotWhitelistZeroAddress();
            if (whitelistAddress[account]) revert AddressAlreadyWhitelisted();
            emit AddressWhitelisted(account);
        } else {
            if (account == address(0))
                revert CannotRemoveZeroAddressFromWhitelist();
            if (!whitelistAddress[account]) revert AddressNotWhitelisted();
            emit AddressRemovedFromWhitelist(account);
        }
        whitelistAddress[account] = add;
    } //c makes sense

    /**
     * @dev Checks if an address is whitelisted
     * @param account The address to check
     * @return A boolean indicating if the address is whitelisted
     */
    function isWhitelisted(address account) external view returns (bool) {
        return whitelistAddress[account];
    }

    /**
     * @dev Internal function to update balances and apply taxes (overrides ERC20's _update)
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        uint256 baseTax = swapTaxRate + burnTaxRate;
        // Skip tax for whitelisted addresses or when fee collector disabled
        if (
            baseTax == 0 ||
            from == address(0) ||
            to == address(0) ||
            whitelistAddress[from] ||
            whitelistAddress[to] ||
            feeCollector == address(0)
        ) {
            super._update(from, to, amount);
            return;
        } //c so if a non-whitelisted address sends tokens to a whitelisted address, no tax is applied ?? this seems to be expected because in RAACToken.test.js, they test that a non-whitelisted address sends tokens to a whitelisted address and no tax is applied so we can assume they meant to do that

        //the if function says if from or to is address(0) then no tax is applied, but when tokens are burnt , the to address is 0 so if a non whitelisted user burns tokens, no tax is applied from this function but there is a tax applied in the burn function
        check = true; //c for testing purposes
        // All other cases where tax is applied
        totalTax = amount.percentMul(baseTax);
        //c check for precision loss here
        burnAmount = (totalTax * burnTaxRate) / baseTax; //c so there is double taxation going on here. so what they do is calculate total tax by taking burn tax and swap tax, summing them up to get base tax and multiplying the rate by the amount to get total tax

        swapfee = totalTax - burnAmount; //c for testing purposes

        //c then they calculate the burn amount by doing burntaxrate/basetax * total tax which is trying to get how much of the total tax is burn tax which is correct and you might think they should do burntaxrate/10000 * totaltax but this will be wrong because the burn tax rate is the tax rate of the total amount which is burntaxrate/10000 * amount so think about it like this. burntaxrate = 10% , swaptaxrate = 5%, amount = 100. So this means base tax rate will be 15% of 100 which is 15. So to get how much of this total tax is burn tax, you do 10/15 * 15 which is 10. So this is correct as this is the same as 10/100 * 100 which is 10. So this is correct

        super._update(from, feeCollector, totalTax - burnAmount);
        super._update(from, address(0), burnAmount); //c so the idea is that if a user transfers tokens, a portion of their tokens will be given to the fee collector and another portion is burnt
        super._update(from, to, amount - totalTax);
    }
}
