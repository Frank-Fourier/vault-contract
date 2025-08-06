import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';

require('dotenv').config({ path: __dirname + '/deployments/.env' });
const { HOODI_API_URL, PRIVATE_KEY, ETHERSCAN_API_KEY } = process.env;

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
    hoodi: {
      url: HOODI_API_URL,
      accounts: PRIVATE_KEY ? [`0x${PRIVATE_KEY}`] : [],
      chainId: 560048,
      gasMultiplier: 10,
    },
  },
  etherscan: {
    apiKey: {
      hoodi: ETHERSCAN_API_KEY || '',
    },
    customChains: [
      {
        network: 'hoodi',
        chainId: 560048,
        urls: {
          apiURL: 'https://api.etherscan.io/v2/api?chainid=560048',
          browserURL: 'https://etherscan.io',
        },
      },
    ],
  },
};

export default config;
