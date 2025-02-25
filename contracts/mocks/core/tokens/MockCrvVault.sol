//SDPX-license-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCrvVault is ERC20, ERC4626 {
    address public crv;
    error CannotDepositZeroShares();

    constructor(address _crv) ERC20("Vault", "VLT") ERC4626(IERC20(_crv)) {
        crv = _crv; // Initialize the crv variable
    }

    function decimals() public pure override(ERC20, ERC4626) returns (uint8) {
        return 18;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        uint256 previewedShares = convertToShares(assets);
        if (previewedShares == 0) {
            revert CannotDepositZeroShares();
        }
        super.deposit(assets, receiver);
    }

    /** @dev See {IERC4626-convertToShares}. */
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        if (totalSupply() == 0) {
            return assets;
        }
        if (totalAssets() == 0) {
            return 0;
        }
        super.convertToShares(assets);
    }
}
