//SDPX-license-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IRAACNFT} from "contracts/interfaces/core/tokens/IRAACNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectERC721 is IERC721Receiver {
    address public rAACNFT;
    address public crvusd;
    error RejectERC721Error();

    constructor(address _raacNFT, address _crvusd) {
        rAACNFT = _raacNFT;
        crvusd = _crvusd;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 token,
        bytes calldata data
    ) external view override returns (bytes4) {
        if (from != address(0)) {
            revert RejectERC721Error();
        }

        return this.onERC721Received.selector;
    }

    function mintNFT(uint256 tokenId, uint256 amounttoPay) external {
        IERC20(crvusd).approve(rAACNFT, amounttoPay);
        IRAACNFT(rAACNFT).mint(tokenId, amounttoPay);
    }

    function transferNFT(address to, uint256 tokenId) external {
        IRAACNFT(rAACNFT).transferFrom(address(this), to, tokenId);
    }
}
