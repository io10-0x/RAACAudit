// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract RAACHousePricesMock {
    mapping(uint256 => uint256) public prices;

    function setTokenPrice(uint256 tokenId, uint256 price) external {
        //c no access control so anyone can set the price of any house but this is a mock so doesnt matter. The real house prices are set by the RAACHousePriceOracle contract so go have a look there. Also see RAACHousePrices.sol to see all functions that oracles call to get prices and set prices
        prices[tokenId] = price;
    } //c if a house price is to be updated using this function, it can be front run by validator watching for this function and then calling mint just before the price is set and then selling the nft on right after for a profit without any risk.The real house prices are set by the RAACHousePriceOracle contract so go have a look there.RAACHousePrices.sol to see all functions that oracles call to get prices and set prices

    function tokenToHousePrice(
        uint256 tokenId
    ) external view returns (uint256) {
        return prices[tokenId];
    }
}
