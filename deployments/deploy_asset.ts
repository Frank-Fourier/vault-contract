import { ethers } from 'hardhat';

async function main() {
  console.log('Deploying Asset (ERC20) contract...');

  const Asset = await ethers.getContractFactory('Asset');
  const asset = await Asset.deploy();

  await asset.waitForDeployment();

  const assetAddress = await asset.getAddress();
  console.log('Asset deployed to:', assetAddress);

  // You can optionally mint more tokens here if needed
  // For example, minting 1000 tokens to another address
  // const recipient = "0x...";
  // const amount = ethers.utils.parseUnits("1000", 18); // Assumes 18 decimals
  // await asset.mint(recipient, amount);
  // console.log(`Minted 1000 tokens to ${recipient}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
