import { ethers } from 'hardhat';

async function main() {
  // --- DEPLOYMENT PARAMETERS ---
  // Replace these with your actual constructor arguments

  const tokenAddress = '0x069DedBb958d5319B13bdBC5219Ca21957b77930'; // Address of the ERC20 token to lock
  const depositFeeRate = 100; // 1% fee (100 basis points)
  const vaultAdmin = '0xaCfFe502637b9Afe6E2b89D2663890a06B6b7B75'; // Address of the vault administrator
  const factoryAddress = '0xaCfFe502637b9Afe6E2b89D2663890a06B6b7B75'; // Address of the VaultFactory
  const feeBeneficiary = '0xaCfFe502637b9Afe6E2b89D2663890a06B6b7B75'; // Address to receive fees
  const vaultTier = 0; // 0: NO_RISK_NO_CROWN, 1: SPLIT_THE_SPOILS, 2: VAULTMASTER_3000

  // --- DEPLOYMENT ---

  console.log('Deploying Vault contract...');

  const Vault = await ethers.getContractFactory('Vault');
  const vault = await Vault.deploy(
    tokenAddress,
    depositFeeRate,
    vaultAdmin,
    factoryAddress,
    feeBeneficiary,
    vaultTier,
  );

  await vault.waitForDeployment();

  console.log('Vault deployed to:', await vault.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
