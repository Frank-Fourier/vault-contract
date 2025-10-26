import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';

require('dotenv').config({ path: __dirname + '/deployments/.env' });
const { BASE_SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY } = process.env;

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: 'hardhat',
  networks: {
    baseSepolia: {
      url: BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org',
      accounts: PRIVATE_KEY ? [`0x${PRIVATE_KEY}`] : [],
      chainId: 84532,
      gasMultiplier: 10,
    },
  },
  etherscan: {
    apiKey: {
      baseSepolia: ETHERSCAN_API_KEY || '',
    },
    customChains: [
      {
        network: 'baseSepolia',
        chainId: 84532,
        urls: {
          apiURL: 'https://api.etherscan.io/v2/api?chainid=84532',
          browserURL: 'https://etherscan.io',
        },
      },
    ],
  },
};

export default config;
