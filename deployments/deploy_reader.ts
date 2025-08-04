import { ethers } from 'hardhat';

async function main() {
  // --- DEPLOYMENT PARAMETERS ---
  // Replace with the address of your already deployed Vault contract
  const vaultAddress = '0x269B56AFa45C3d41811b16347C32c18F5F2E29Ce';

  // --- DEPLOYMENT ---

  console.log('Deploying VaultReader contract...');

  const VaultReader = await ethers.getContractFactory('VaultReader');
  const vaultReader = await VaultReader.deploy(vaultAddress);

  await vaultReader.waitForDeployment();

  console.log('VaultReader deployed to:', await vaultReader.getAddress());
  console.log('Reading data from Vault at:', await vaultReader.vault());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
