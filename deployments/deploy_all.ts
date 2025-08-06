import { ethers } from 'hardhat';
import { Vault, VaultDeployer, VaultFactory } from '../typechain-types';

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deploying contracts with the account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    'ETH',
  );

  console.log('\n--- 1. Deploying Test Asset (ERC20) ---');
  const Asset = await ethers.getContractFactory('Asset');
  const asset = await Asset.deploy();
  await asset.waitForDeployment();
  const assetAddress = await asset.getAddress();
  console.log('Test Asset (ERC20) deployed to:', assetAddress);

  console.log('\n--- 2. Deploying Master Vault (Implementation) ---');
  const Vault = await ethers.getContractFactory('Vault');
  const vaultImplementation = (await Vault.deploy()) as Vault;
  await vaultImplementation.waitForDeployment();
  const vaultImplementationAddress = await vaultImplementation.getAddress();
  console.log(
    'Master Vault implementation deployed to:',
    vaultImplementationAddress,
  );

  console.log('\n--- 3. Deploying VaultDeployer ---');
  const VaultDeployer = await ethers.getContractFactory('VaultDeployer');
  const vaultDeployer = (await VaultDeployer.deploy(
    deployer.address,
  )) as VaultDeployer;
  await vaultDeployer.waitForDeployment();
  const vaultDeployerAddress = await vaultDeployer.getAddress();
  console.log('VaultDeployer deployed to:', vaultDeployerAddress);

  console.log('\n--- 4. Deploying VaultFactory ---');
  const VaultFactory = await ethers.getContractFactory('VaultFactory');
  const vaultFactory = (await VaultFactory.deploy(
    deployer.address, // Factory Owner
    '0x0000000000000000000000000000000000000000', // Main Vault Address (can be updated later)
    deployer.address, // Main Fee Beneficiary
  )) as VaultFactory;
  await vaultFactory.waitForDeployment();
  const vaultFactoryAddress = await vaultFactory.getAddress();
  console.log('VaultFactory deployed to:', vaultFactoryAddress);

  console.log('\n--- 5. Wiring the Contracts Together ---');
  await vaultFactory.setVaultImplementation(vaultImplementationAddress);
  console.log('-> Factory configured with Vault implementation.');
  await vaultFactory.setVaultDeployer(vaultDeployerAddress);
  console.log('-> Factory configured with Vault deployer.');
  await vaultDeployer.transferOwnership(vaultFactoryAddress);
  console.log('-> VaultDeployer ownership transferred to VaultFactory.');

  console.log('\n--- 6. Creating a Sample Vault (Clone) via Factory ---');
  const tx = await vaultFactory.createVault(
    assetAddress, // _vaultToken
    100, // _depositFeeRate (1%)
    deployer.address, // _vaultAdmin
    deployer.address, // _feeBeneficiary
    0, // _tier (NO_RISK_NO_CROWN)
    { value: ethers.parseEther('0') }, // Deployment fee for Tier 0 is 0
  );
  const receipt = await tx.wait();
  if (!receipt) {
    throw new Error(
      'Transaction for creating vault failed, no receipt returned.',
    );
  }

  const vaultCreatedEvent = receipt.logs
    .map((log) => {
      try {
        return vaultFactory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((event) => event?.name === 'VaultCreated');

  if (!vaultCreatedEvent) {
    throw new Error(
      'Could not find the VaultCreated event in the transaction receipt.',
    );
  }

  const sampleVaultAddress = vaultCreatedEvent.args.vaultAddress;
  console.log('Sample Vault (clone) created at:', sampleVaultAddress);

  console.log('\n--- 7. Deploying VaultReader ---');
  const VaultReader = await ethers.getContractFactory('VaultReader');
  const vaultReader = await VaultReader.deploy(sampleVaultAddress);
  await vaultReader.waitForDeployment();
  const vaultReaderAddress = await vaultReader.getAddress();
  console.log('VaultReader deployed to:', vaultReaderAddress);
  console.log('-> VaultReader is reading from:', await vaultReader.vault());

  console.log('\n✅ Deployment and setup complete!');
  console.log({
    deployer: deployer.address,
    assetToken: assetAddress,
    vaultFactory: vaultFactoryAddress,
    vaultDeployer: vaultDeployerAddress,
    vaultImplementation: vaultImplementationAddress,
    sampleVault: sampleVaultAddress,
    vaultReader: vaultReaderAddress,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
