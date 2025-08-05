// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IVaultFactory.sol";

/**
 * @title IVaultDeployer
 * @dev Interface for the VaultDeployer contract.
 */
interface IVaultDeployer {
    /**
     * @dev Deploys a clone of the implementation contract and initializes it.
     * @param implementation The address of the master Vault implementation.
     * @param initializeData The encoded call to the initialize function.
     * @return The address of the newly deployed and initialized Vault clone.
     */
    function deployVault(
        address implementation,
        bytes calldata initializeData
    ) external returns (address);
}