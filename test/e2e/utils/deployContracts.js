import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;

async function deployContract(name, args = []) {
  const Factory = await ethers.getContractFactory(name);
  const contract = await Factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

export async function deployContracts(owner, user1, user2, user3) {
  // Deploy mock CRVUSD first
  const crvUSD = await deployContract("crvUSDToken", [owner.address]);
  await crvUSD.setMinter(owner.address);

  // RAAC token
  const TAX_RATE = 200n; // 2% in basis points
  const BURN_RATE = 50n; // 0.5% in basis points
  const raacToken = await deployContract("RAACToken", [
    owner.address,
    TAX_RATE,
    BURN_RATE,
  ]);

  const veRAACToken = await deployContract("veRAACToken", [raacToken.target]);
  const releaseOrchestrator = await deployContract("RAACReleaseOrchestrator", [
    raacToken.target,
  ]);

  // Price Oracle
  const housePrices = await deployContract("RAACHousePrices", [owner.address]);
  await housePrices.setOracle(owner.address);

  // Deploy NFT
  const nft = await deployContract("RAACNFT", [
    crvUSD.target,
    housePrices.target,
    owner.address,
  ]);

  //c get new mockerc20 contract to use as reserve asset
  const altReserveAsset = await deployContract("RAACMockERC20", [
    owner.address,
  ]);

  // Deploy Pool Tokens
  const rToken = await deployContract("RToken", [
    "RToken",
    "RT",
    owner.address,
    crvUSD.target,
    //altReserveAsset.target,
  ]);
  const debtToken = await deployContract("DebtToken", [
    "DebtToken",
    "DT",
    owner.address,
  ]);

  const initialPrimeRate = ethers.parseUnits("0.1", 27);

  // Deploy Lending Pool
  const lendingPool = await deployContract("LendingPool", [
    crvUSD.target,
    //altReserveAsset.target,
    rToken.target,
    debtToken.target,
    nft.target,
    housePrices.target,
    initialPrimeRate,
  ]);

  //c deploy reservelibrarymock
  const reserveLibrary = await deployContract("ReserveLibraryMock", []);

  // Deploy Treasury and Funds
  const treasury = await deployContract("Treasury", [owner.address]);
  const repairFund = await deployContract("Treasury", [owner.address]); // Repair Fund is another type of treasury - we can use same contract

  const feeCollector = await deployContract("FeeCollector", [
    raacToken.target,
    veRAACToken.target,
    treasury.target,
    repairFund.target,
    owner.address,
  ]);

  // Deploy Stability Pool and DEToken
  const deToken = await deployContract("DEToken", [
    "DEToken",
    "DEToken",
    owner.address,
    rToken.target,
  ]);
  const stabilityPool = await deployContract("StabilityPool", [owner.address]);

  // Deploy RAAC Minter
  const minter = await deployContract("RAACMinter", [
    raacToken.target,
    stabilityPool.target,
    lendingPool.target,
    treasury.target,
  ]);

  // Initialize contracts
  await raacToken.setFeeCollector(feeCollector.target);
  await raacToken.manageWhitelist(await feeCollector.getAddress(), true);
  await raacToken.manageWhitelist(await veRAACToken.getAddress(), true);
  await raacToken.manageWhitelist(owner.address, true);

  await raacToken.setMinter(owner.address);
  await raacToken.mint(user2.address, ethers.parseEther("1000"));
  await raacToken.mint(user3.address, ethers.parseEther("1000"));

  await raacToken.setMinter(minter.target);

  await feeCollector.grantRole(
    await feeCollector.FEE_MANAGER_ROLE(),
    owner.address
  );
  await feeCollector.grantRole(
    await feeCollector.EMERGENCY_ROLE(),
    owner.address
  );
  await feeCollector.grantRole(
    await feeCollector.DISTRIBUTOR_ROLE(),
    owner.address
  );

  await rToken.setReservePool(lendingPool.target);
  await debtToken.setReservePool(lendingPool.target);
  await deToken.setStabilityPool(stabilityPool.target);
  // Set up minter configuration
  await raacToken.transferOwnership(minter.target);
  await rToken.transferOwnership(lendingPool.target);
  await debtToken.transferOwnership(lendingPool.target);

  await stabilityPool.initialize(
    rToken.target,
    deToken.target,
    raacToken.target,
    minter.target,
    crvUSD.target,
    lendingPool.target
  );

  // Set up lending pool configuration
  await lendingPool.setStabilityPool(stabilityPool.target);

  return {
    crvUSD,
    raacToken,
    veRAACToken,
    releaseOrchestrator,
    housePrices,
    nft,
    rToken,
    debtToken,
    lendingPool,
    treasury,
    repairFund,
    feeCollector,
    deToken,
    stabilityPool,
    minter,
    reserveLibrary,
    altReserveAsset,
  };
}
