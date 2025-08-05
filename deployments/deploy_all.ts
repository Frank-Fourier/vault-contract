import { ethers } from 'hardhat';

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deploying contracts with the account:', deployer.address);

  // --- 1. Deploy Master Vault (the implementation) ---
  const Vault = await ethers.getContractFactory('Vault');
  const vaultImplementation = await Vault.deploy();
  await vaultImplementation.waitForDeployment();
  console.log(
    'Master Vault implementation deployed to:',
    vaultImplementation.target,
  );

  // --- 2. Deploy VaultDeployer ---
  const VaultDeployer = await ethers.getContractFactory('VaultDeployer');
  const vaultDeployer = await VaultDeployer.deploy(deployer.address); // Initially owned by the deployer
  await vaultDeployer.waitForDeployment();
  console.log('VaultDeployer deployed to:', vaultDeployer.target);

  // --- 3. Deploy VaultFactory ---
  const mainFeeBeneficiary = deployer.address; // Or another address
  const mainVaultAddress = '0x0000000000000000000000000000000000000000'; // Placeholder, can be updated later

  const VaultFactory = await ethers.getContractFactory('VaultFactory');
  const vaultFactory = await VaultFactory.deploy(
    deployer.address, // Factory Owner
    mainVaultAddress, // Main Vault Address (can be updated)
    mainFeeBeneficiary, // Main Fee Beneficiary
  );
  await vaultFactory.waitForDeployment();
  console.log('VaultFactory deployed to:', vaultFactory.target);

  // --- 4. Wire the Contracts Together ---
  console.log('\nWiring contracts...');

  // Set the implementation and deployer addresses in the factory
  await vaultFactory.setVaultImplementation(vaultImplementation.target);
  console.log('-> Factory configured with Vault implementation.');

  await vaultFactory.setVaultDeployer(vaultDeployer.target);
  console.log('-> Factory configured with Vault deployer.');

  // Transfer ownership of the deployer to the factory for security
  await vaultDeployer.transferOwnership(vaultFactory.target);
  console.log('-> VaultDeployer ownership transferred to VaultFactory.');

  console.log('\n✅ Deployment and setup complete!');
  console.log({
    vaultFactory: vaultFactory.target,
    vaultDeployer: vaultDeployer.target,
    vaultImplementation: vaultImplementation.target,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
