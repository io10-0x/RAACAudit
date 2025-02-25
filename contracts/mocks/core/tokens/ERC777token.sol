//SDPX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC777} from "./ERC777.sol";

contract ERC777Token is ERC777 {
    uint256 public constant initialSupply = 10000000000000e18;

    constructor(address owner) ERC777("ERC777Token", "SSST", new address[](0)) {
        _mint(owner, initialSupply, "", "");
    }
}
