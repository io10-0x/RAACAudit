import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;

describe("RAACNFT", () => {
  let raacNFT;
  let crvUSD;
  let housePrices;
  let owner;
  let user1;
  let user2;

  const INITIAL_BATCH_SIZE = 3n;
  const HOUSE_PRICE = ethers.parseEther("100");
  const TOKEN_ID = 1;

  beforeEach(async () => {
    [owner, user1, user2] = await ethers.getSigners();

    const CrvUSDToken = await ethers.getContractFactory("crvUSDToken");
    crvUSD = await CrvUSDToken.deploy(owner.address);
    await crvUSD.setMinter(owner.address);

    const HousePrices = await ethers.getContractFactory("RAACHousePrices");
    housePrices = await HousePrices.deploy(owner.address);
    await housePrices.setOracle(owner.address);

    await housePrices.setHousePrice(TOKEN_ID, HOUSE_PRICE);
    await housePrices.setHousePrice(TOKEN_ID + 1, HOUSE_PRICE);
    const RAACNFT = await ethers.getContractFactory("RAACNFT");
    raacNFT = await RAACNFT.deploy(
      crvUSD.target,
      housePrices.target,
      owner.address
    );

    await crvUSD.mint(user1.address, ethers.parseEther("1000"));
    await crvUSD.mint(user2.address, ethers.parseEther("1000"));
  });

  describe("Initialization", () => {
    const newBaseURI = "ipfs://squawk7700/";

    it("should initialize with correct values", async () => {
      expect(await raacNFT.token()).to.equal(await crvUSD.getAddress());
      expect(await raacNFT.raac_hp()).to.equal(await housePrices.getAddress());
      expect(await raacNFT.owner()).to.equal(owner.address);
      expect(await raacNFT.currentBatchSize()).to.equal(INITIAL_BATCH_SIZE);
    });

    it("should revert with zero addresses", async () => {
      const RAACNFT = await ethers.getContractFactory("RAACNFT");
      await expect(
        RAACNFT.deploy(
          ethers.ZeroAddress,
          await housePrices.getAddress(),
          owner.address
        )
      ).to.be.revertedWithCustomError(RAACNFT, "RAACNFT__InvalidAddress");

      await expect(
        RAACNFT.deploy(
          await crvUSD.getAddress(),
          ethers.ZeroAddress,
          owner.address
        )
      ).to.be.revertedWithCustomError(RAACNFT, "RAACNFT__InvalidAddress");

      await expect(
        RAACNFT.deploy(
          await crvUSD.getAddress(),
          await housePrices.getAddress(),
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(RAACNFT, "OwnableInvalidOwner");
    });
    it("should return correct house price", async () => {
      const price = await raacNFT.getHousePrice(TOKEN_ID);
      expect(price).to.equal(HOUSE_PRICE);
    });

    it("should update base URI successfully", async () => {
      await raacNFT.connect(owner).setBaseUri(newBaseURI);
      expect(await raacNFT.baseURI()).to.equal(newBaseURI);
    });

    it("should revert when non-owner tries to update base URI", async () => {
      await expect(
        raacNFT.connect(user1).setBaseUri(newBaseURI)
      ).to.be.revertedWithCustomError(raacNFT, "OwnableUnauthorizedAccount");
    });
  });

  describe("Minting", () => {
    beforeEach(async () => {
      await crvUSD
        .connect(user1)
        .approve(raacNFT.getAddress(), ethers.parseEther("1000"));
    });

    it("shouldmintNFTsuccessfully", async () => {
      await expect(raacNFT.connect(user1).mint(TOKEN_ID, HOUSE_PRICE))
        .to.emit(raacNFT, "NFTMinted")
        .withArgs(user1.address, TOKEN_ID, HOUSE_PRICE);

      expect(await raacNFT.ownerOf(TOKEN_ID)).to.equal(user1.address);
      expect(await crvUSD.balanceOf(raacNFT.getAddress())).to.equal(
        HOUSE_PRICE
      );
    });

    it("should refund excess payment", async () => {
      const excessAmount = HOUSE_PRICE + ethers.parseEther("10");
      const initialBalance = await crvUSD.balanceOf(user1.address);

      await raacNFT.connect(user1).mint(TOKEN_ID, excessAmount);

      const finalBalance = await crvUSD.balanceOf(user1.address);
      expect(initialBalance - finalBalance).to.equal(HOUSE_PRICE);
    });

    it("should revert with insufficient funds", async () => {
      const insufficientAmount = HOUSE_PRICE - ethers.parseEther("1");
      await expect(
        raacNFT.connect(user1).mint(TOKEN_ID, insufficientAmount)
      ).to.be.revertedWithCustomError(
        raacNFT,
        "RAACNFT__InsufficientFundsMint"
      );
    });

    it("should revert with invalid house price", async () => {
      await housePrices.setHousePrice(TOKEN_ID, 0);
      await expect(
        raacNFT.connect(user1).mint(TOKEN_ID, HOUSE_PRICE)
      ).to.be.revertedWithCustomError(raacNFT, "RAACNFT__HousePrice");
    });

    it("should track total supply correctly", async () => {
      const initialSupply = await raacNFT.totalSupply();
      await raacNFT.connect(user1).mint(TOKEN_ID, HOUSE_PRICE);
      expect(await raacNFT.totalSupply()).to.equal(initialSupply + 1n);
    });

    it("doesnotrevertwhenhousepricedoesnothave18decimals", async () => {
      //c for testing purposes
      await housePrices.setHousePrice(TOKEN_ID, ethers.parseEther("0.1"));
      await expect(
        raacNFT.connect(user1).mint(TOKEN_ID, ethers.parseEther("0.1"))
      )
        .to.emit(raacNFT, "NFTMinted")
        .withArgs(user1.address, TOKEN_ID, ethers.parseEther("0.1"));

      expect(await raacNFT.ownerOf(TOKEN_ID)).to.equal(user1.address);
      expect(await crvUSD.balanceOf(raacNFT.getAddress())).to.equal(
        ethers.parseEther("0.1")
      );
    });
  });

  describe("Batch Management", () => {
    it("should add new batch successfully", async () => {
      const addBatchSize = 5n;
      const initialBatchSize = await raacNFT.currentBatchSize();

      await raacNFT.connect(owner).addNewBatch(addBatchSize);

      expect(await raacNFT.currentBatchSize()).to.equal(
        initialBatchSize + addBatchSize
      );
    });

    it("should revert when non-owner tries to add batch", async () => {
      await expect(
        raacNFT.connect(user1).addNewBatch(5n)
      ).to.be.revertedWithCustomError(raacNFT, "OwnableUnauthorizedAccount");
    });

    it("should revert with zero batch size", async () => {
      await expect(
        raacNFT.connect(owner).addNewBatch(0)
      ).to.be.revertedWithCustomError(raacNFT, "RAACNFT__BatchSize");
    });
  });
});
