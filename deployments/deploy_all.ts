import { ethers, run } from 'hardhat';
import { Vault, VaultDeployer, VaultFactory } from '../typechain-types';

// Helper function to wait for a few seconds
const delay = (ms: number) => new Promise((res) => setTimeout(res, ms));

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
  const deployerArg = deployer.address;
  const VaultDeployer = await ethers.getContractFactory('VaultDeployer');
  const vaultDeployer = (await VaultDeployer.deploy(
    deployerArg,
  )) as VaultDeployer;
  await vaultDeployer.waitForDeployment();
  const vaultDeployerAddress = await vaultDeployer.getAddress();
  console.log('VaultDeployer deployed to:', vaultDeployerAddress);

  console.log('\n--- 4. Deploying VaultFactory ---');
  const factoryArgs = [
    deployer.address, // Factory Owner
    '0x0000000000000000000000000000000000000000', // Main Vault Address (can be updated later)
    deployer.address, // Main Fee Beneficiary
  ];
  const VaultFactory = await ethers.getContractFactory('VaultFactory');
  const vaultFactory = (await VaultFactory.deploy(
    factoryArgs[0],
    factoryArgs[1],
    factoryArgs[2],
  )) as VaultFactory;
  await vaultFactory.waitForDeployment();
  const vaultFactoryAddress = await vaultFactory.getAddress();
  console.log('VaultFactory deployed to:', vaultFactoryAddress);

  console.log('\n--- 5. Wiring the Contracts Together ---');
  const tx_set_impl = await vaultFactory.setVaultImplementation(
    vaultImplementationAddress,
  );
  await tx_set_impl.wait(2); // Wait for 2 block confirmations
  console.log('-> Factory configured with Vault implementation.');

  const tx_set_deployer =
    await vaultFactory.setVaultDeployer(vaultDeployerAddress);
  await tx_set_deployer.wait(2); // Wait for 2 block confirmations
  console.log('-> Factory configured with Vault deployer.');

  const tx_transfer_owner =
    await vaultDeployer.transferOwnership(vaultFactoryAddress);
  await tx_transfer_owner.wait(2); // Wait for 2 block confirmations
  console.log('-> VaultDeployer ownership transferred to VaultFactory.');

  console.log('\n--- 6. Creating a Sample Vault (Clone) via Factory ---');
  const vaultMetadata = JSON.stringify({
    name: 'Sample Test Vault',
    description: 'A sample vault for testing the vault system',
    image: 'https://example.com/vault-logo.png',
  });

  const tx = await vaultFactory.createVault(
    assetAddress, // _vaultToken
    500, // _depositFeeRate (5%), required for Tier 0
    deployer.address, // _vaultAdmin
    deployer.address, // _feeBeneficiary
    vaultMetadata, // _metadataURI
    0, // _tier (NO_RISK_NO_CROWN)
    { value: ethers.parseEther('0') }, // Deployment fee for Tier 0 is 0
  );
  const receipt = await tx.wait(2); // Wait for 2 block confirmations
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

  console.log('\n--- 7. Verifying Contracts on Etherscan ---');
  console.log('Waiting for 30 seconds before starting verification...');
  await delay(30000);

  const contractsToVerify = [
    { name: 'Asset', address: assetAddress, args: [] },
    {
      name: 'Vault (Implementation)',
      address: vaultImplementationAddress,
      args: [],
    },
    {
      name: 'VaultDeployer',
      address: vaultDeployerAddress,
      args: [deployerArg],
    },
    { name: 'VaultFactory', address: vaultFactoryAddress, args: factoryArgs },
  ];

  for (const contract of contractsToVerify) {
    console.log(`Verifying ${contract.name}...`);
    try {
      await run('verify:verify', {
        address: contract.address,
        constructorArguments: contract.args,
      });
      console.log(`-> ${contract.name} verified successfully.`);
    } catch (error: any) {
      if (error.message.toLowerCase().includes('already verified')) {
        console.log(`-> ${contract.name} is already verified.`);
      } else {
        console.error(`!> Verification for ${contract.name} failed:`, error);
      }
    }
  }

  console.log('\n✅ Deployment, setup, and verification complete!');
  console.log({
    deployer: deployer.address,
    assetToken: assetAddress,
    vaultFactory: vaultFactoryAddress,
    vaultDeployer: vaultDeployerAddress,
    vaultImplementation: vaultImplementationAddress,
    sampleVault: sampleVaultAddress,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
