// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title VaultDeployer
 * @dev A contract responsible for deploying new Vault instances using the clone pattern.
 *      It is owned and controlled by the VaultFactory.
 */
contract VaultDeployer is Ownable {
    constructor(address _initialOwner) Ownable(_initialOwner) {
        require(_initialOwner != address(0), "V.D.: Invalid owner");
    }

    /**
     * @dev Deploys a clone of the implementation contract and initializes it.
     * @param implementation The address of the master Vault implementation.
     * @param initializeData The encoded call to the initialize function.
     * @return The address of the newly deployed and initialized Vault clone.
     */
    function deployVault(
        address implementation,
        bytes calldata initializeData
    ) external onlyOwner returns (address) {
        address instance = Clones.clone(implementation);
        (bool success, ) = instance.call(initializeData);
        require(success, "V.D.: Initialization failed");
        return instance;
    }
}
