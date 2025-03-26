# Vault and VaultFactory Contracts

A robust smart contract system for token locking with linear decay voting power mechanics. This project consists of two main components: the `Vault` contract for locking tokens and managing user participation, and the `VaultFactory` contract for creating and managing multiple `Vault` instances. 

## Overview

The `Vault` contract allows users to lock their tokens for a specified duration, providing them with voting power that decays over time. This design encourages users to re-lock their tokens to maintain or increase their voting power, thereby enhancing governance participation.

The `VaultFactory` contract serves as a factory for creating new `Vault` instances, allowing approved partners to deploy vaults with specific parameters.

## Core Mechanics

### Voting Power Mechanism
- **Linear Decay**: Voting power decreases linearly from deposit until lock end
- **Lock Extension**: Users can extend their lock duration or add more tokens to maintain/increase voting power
- **Peak Power**: Initial voting power is proportional to locked amount and duration

### Epoch System
- **Reward Distribution**: Epochs allow for periodic reward distribution based on voting power
- **Participation**: Users can participate in epochs to earn rewards
- **Dynamic Power Calculation**: Voting power is calculated using the area under the decay curve

### Fee Structure
- Split fee system between vault-specific beneficiary and main beneficiary
- Configurable deposit fee rate
- Fees collected on deposits

## Features

### Vault Contract

- **Token Locking with Decreasing Voting Power**: Implements a mechanism where voting power decreases over the lock period, incentivizing users to re-lock their tokens for longer durations to maintain their voting power.
- **Fee Collection and Reward Distribution**: Efficiently collects fees on deposits and distributes rewards based on the duration tokens are held, promoting longer lock-ins.
- **Emergency Unlock Feature**: Allows for an emergency withdrawal of tokens under specific conditions, ensuring user funds' safety.
- **Enhanced Security and Role-Based Functions**: Utilizes OpenZeppelin libraries for security while providing role-based functions for administrative control.

### VaultFactory Contract

- **Create Vaults**: Allows approved partners to create new `Vault` instances with specified parameters, including the token to lock, deposit fee rate, admin address, and fee beneficiary.
- **Manage Approved Partners**: The factory can approve or remove partners who are allowed to create vaults.
- **Track Deployed Vaults**: Maintains a list of all deployed vaults for easy management and tracking.

## Getting Started

### Prerequisites

- Node.js 20.x
- Hardhat

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   ```
2. Install dependencies:
   ```bash
   npm install
   ```

### Deployment

1. Deploy the `VaultFactory` contract:
   ```bash
   npm run deploy-sepolia
   ```
2. Use the deployed `VaultFactory` contract to create new `Vault` instances as needed.

### Usage

1. **Creating a Vault**: Approved partners can call the `createVault` function on the `VaultFactory` contract, providing the necessary parameters to deploy a new `Vault`.
2. **Interacting with a Vault**: Users can deposit tokens into the vault, extend their lock duration, and participate in epochs to earn rewards.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE) file for details.
