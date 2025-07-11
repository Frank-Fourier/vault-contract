import { ethers } from 'hardhat';
import { VaultFactory } from '../typechain-types';

async function main() {
  console.log('Starting VaultFactory deployment...');

  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log('Deploying with account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    'ETH',
  );

  // Configuration - Update these addresses for your deployment
  const config = {
    owner: deployer.address, // or specify a different owner address
    mainVaultAddress: deployer.address, // Replace with actual main vault address if different
    mainFeeBeneficiary: deployer.address, // Replace with actual fee beneficiary address
  };

  console.log('Deployment configuration:');
  console.log('- Owner:', config.owner);
  console.log('- Main Vault Address:', config.mainVaultAddress);
  console.log('- Main Fee Beneficiary:', config.mainFeeBeneficiary);

  // Get the contract factory
  const VaultFactory = await ethers.getContractFactory('VaultFactory');

  // Estimate gas for deployment
  const deploymentData = VaultFactory.interface.encodeDeploy([
    config.owner,
    config.mainVaultAddress,
    config.mainFeeBeneficiary,
  ]);

  const gasEstimate = await ethers.provider.estimateGas({
    data: deploymentData,
  });

  console.log('Estimated gas for deployment:', gasEstimate.toString());

  // Deploy the contract
  console.log('Deploying VaultFactory...');
  const factory: VaultFactory = await VaultFactory.deploy(
    config.owner,
    config.mainVaultAddress,
    config.mainFeeBeneficiary,
  );

  // Wait for deployment to be mined
  await factory.waitForDeployment();

  const factoryAddress = await factory.getAddress();
  console.log('VaultFactory Contract Deployed to Address:', factoryAddress);

  // Verify deployment was successful
  console.log('Verifying deployment...');
  const code = await ethers.provider.getCode(factoryAddress);
  if (code === '0x') {
    throw new Error('Contract deployment failed - no code at deployed address');
  }

  // Test basic contract functionality
  console.log('Testing contract functionality...');
  const owner = await factory.owner();
  const mainFeeBeneficiary = await factory.mainFeeBeneficiary();

  console.log('Contract owner:', owner);
  console.log('Main fee beneficiary:', mainFeeBeneficiary);
  console.log('Deployed vaults count:', await factory.getDeployedVaultsCount());

  // Save deployment info
  const deploymentInfo = {
    contractName: 'VaultFactory',
    address: factoryAddress,
    deployer: deployer.address,
    deploymentTime: new Date().toISOString(),
    network: (await ethers.provider.getNetwork()).name,
    txHash: factory.deploymentTransaction()?.hash,
    gasUsed: gasEstimate.toString(),
    config: config,
  };

  console.log('\n=== DEPLOYMENT SUCCESSFUL ===');
  console.log('Contract Address:', factoryAddress);
  console.log('Transaction Hash:', factory.deploymentTransaction()?.hash);
  console.log('Network:', (await ethers.provider.getNetwork()).name);
  console.log('Deployer:', deployer.address);

  // Optionally save to file
  const fs = require('fs');
  const path = require('path');

  const deploymentsDir = path.join(__dirname, '..', 'deployments', 'addresses');
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const network = (await ethers.provider.getNetwork()).name;
  const filename = `${network}-VaultFactory.json`;

  fs.writeFileSync(
    path.join(deploymentsDir, filename),
    JSON.stringify(deploymentInfo, null, 2),
  );

  console.log('Deployment info saved to:', `deployments/addresses/${filename}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:');
    console.error(error);
    process.exit(1);
  });
