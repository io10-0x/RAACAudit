// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/core/oracles/IRAACHousePrices.sol";
import "../../interfaces/core/tokens/IRAACNFT.sol";

contract RAACNFT is ERC721, ERC721Enumerable, Ownable, IRAACNFT {
    using SafeERC20 for IERC20;

    IERC20 public token;
    IRAACHousePrices public raac_hp;

    uint256 public currentBatchSize = 3;

    string public baseURI =
        "ipfs://QmZzEbTnUWs5JDzrLKQ9yGk1kvszdnwdMaVw9vNgjCFLo2/";

    constructor(
        address _token,
        address _housePrices,
        address initialOwner
    ) ERC721("RAAC NFT", "RAACNFT") Ownable(initialOwner) {
        if (
            _token == address(0) ||
            _housePrices == address(0) ||
            initialOwner == address(0)
        ) revert RAACNFT__InvalidAddress();
        token = IERC20(_token);
        raac_hp = IRAACHousePrices(_housePrices);
    } //c since there is a constructor here, we know there is no chance they have plans to upgrade the contracts which means any errors made here are permanent

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function mint(uint256 _tokenId, uint256 _amount) public override {
        uint256 price = raac_hp.tokenToHousePrice(_tokenId);
        /*c TO summarize: we have a backend api. That api contains the pricing of the houses. The auditors will be regularly auditing the properties and updating the prices there 1-3 times a year. These firms will have access to the API for sending updates. The chainlink functions, ones a request is sent, get the data from the api and through a decentralized manner, off ramps the data to the RAACHousePrices smart contract. That smart contract is onlyOracle to ensure that only chainlink oracle nodes can update the price. Then, if we need to read the data, we can just call getLatestPrice. See RAACHousePrices.sol to see all functions that oracles call to get prices and set prices*/

        //c a1 assumes that the price of the house returned has 18 decimals. I cannot confirm that because when testing locally, they use a mock where price is set manually. The real house prices are set by the RAACHousePriceOracle contract and in that contract, there is a _processResponse function which is called after the data is received from the oracle. it returns the price in bytes and I cannot see how many decimals it has when it is decoded. Just in case it isnt returned as 18 decimals, there should be a check here to ensure that the price always has 18 decimals.

        if (price == 0) {
            revert RAACNFT__HousePrice();
        }
        if (price > _amount) {
            revert RAACNFT__InsufficientFundsMint();
        }
        //c a2: assumes that 0 and if the price is > amount are the only invalid states.
        // bugREPORTED There should also be a check that the price gotten from chainlink functions has 18 decimals as the response from chainlink functions can be any uint256. To do this, you can configure a minimum price variable to be 1e18 and then check if the price is greater than or equal to the minimum price. If it is not, then revert with an error message that the price is invalid. This is important because if the price is not 18 decimals, then the user will be minting the nft for the wrong price and the house price will be incorrect. This is a critical bug because the house price is the most important part of the nft and if it is wrong, then the nft is useless. This is similar to how chainlink price feeds where each price feed contract has an amount of decimals specified so the same has to be case here.

        // transfer erc20 from user to contract - requires pre-approval from user
        token.safeTransferFrom(msg.sender, address(this), _amount);
        //c token is going to be crvUSD,  so far looked at crv usd and it is written in vyper. looks like any regular erc20 but it has an interesting permit function which we can come back and look at later as this might produce some interesting stuff

        // mint tokenId to user
        _safeMint(msg.sender, _tokenId);
        //c this function contains a hook where if the receiver is a contract, they can implement the onERC721Received function which will be called when the token is received and they can do anything with this so keep that in mind

        //c there is a ERC721Enumerable contract that this contract inherits from so when safeMint is called and _update is called inside this safemint function, note that the _update that runs is the function in ERC721Enumerable.sol as that overrides _update that is in ERC721.sol and the extra functionality from ERC721Enumerable simply adds an array which tracks all tokens being minted and

        // If user approved more than necessary, refund the difference
        if (_amount > price) {
            uint256 refundAmount = _amount - price;
            token.safeTransfer(msg.sender, refundAmount);
        } //c all assumptions about this code block check out

        //q could I enter a tiny amount above price and cause a DOS here??

        emit NFTMinted(msg.sender, _tokenId, price);
    }

    function getHousePrice(
        uint256 _tokenId
    ) public view override returns (uint256) {
        return raac_hp.tokenToHousePrice(_tokenId);
    }

    function addNewBatch(uint256 _batchSize) public override onlyOwner {
        if (_batchSize == 0) revert RAACNFT__BatchSize();
        currentBatchSize += _batchSize;
    } //c this is a feature of ERC721 enumerable that allows users to mint nfts in batches. This is not implemented for RAAC Nft'as the above mint function only allows minting a single token id at a time so this function is out of scope

    function setBaseUri(string memory _uri) external override onlyOwner {
        baseURI = _uri;
        emit BaseURIUpdated(_uri);
    }

    //c there is a base uri but no token uri here so in case you were wondering where tf the token uri is, Yes, it's expected as we intend to receive this information by the launch from a 3rd party. As context, there is a business safe-guards in the minting process by the means of Instruxi, so there will be another ERC interface that will replace the RAACNFT one within the Lending Pool, or at minimum an URI to use at launch. The submitted code has the RAACNFT part of it, so consider it as it is and discard Instruxi for now, this above is just context for how the metadata will be provided to users to better answer you

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721, ERC721Enumerable) {
        if (account == address(0)) revert RAACNFT__InvalidAddress();
        super._increaseBalance(account, value);
    } //c not in scope

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        if (to == address(0)) revert RAACNFT__InvalidAddress(); //c why is this added here. to will only be address(0) if the token is being burned and as a result of adding this check, no token can be burned.

        //c this has been cleared up by dev. see comments: I don't think there is a clear intend for those to be burn as they would be more valuable if the protocol acquires them (because then the protocol own a RWA and it incentivise all RAAC holders), would such burn mechanism happen (sale of the property), its effect will probably be in the form of setHousePrice(0) and the NFT kept as a "souvenir token". as a result, this isnt a real issue but just something to note
        return super._update(to, tokenId, auth);
    }
}
