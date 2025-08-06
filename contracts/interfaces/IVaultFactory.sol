// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IVaultFactory
 * @dev Interface for the VaultFactory contract, defining shared data structures and functions.
 */
interface IVaultFactory {
    /**
     * @dev Defines the different tiers available for vaults.
     */
    enum VaultTier {
        NO_RISK_NO_CROWN,
        SPLIT_THE_SPOILS,
        VAULTMASTER_3000
    }

    /**
     * @dev Defines the configuration for a specific vault tier.
     * @param deploymentFee The cost in ETH to deploy a vault of this tier.
     * @param performanceFeeRate The fee taken from rewards, in basis points.
     * @param minDepositFeeRate The minimum allowed deposit fee, in basis points.
     * @param maxDepositFeeRate The maximum allowed deposit fee, in basis points.
     * @param platformDepositShare The share of the deposit fee that goes to the platform, in basis points.
     * @param canAdjustDepositFee A boolean indicating if the vault admin can change the deposit fee.
     * @param tierName The human-readable name of the tier.
     */
    struct TierConfig {
        uint256 deploymentFee;
        uint256 performanceFeeRate;
        uint256 minDepositFeeRate;
        uint256 maxDepositFeeRate;
        uint256 platformDepositShare;
        bool    canAdjustDepositFee;
        string  tierName;
    }

    /**
     * @dev Returns the address of the main fee beneficiary for the platform.
     * @return The address of the main fee beneficiary.
     */
    function mainFeeBeneficiary() external view returns (address);

    /**
     * @dev Returns the tier configuration for a specific vault.
     * @param vaultAddress The address of the vault.
     * @return The configuration for the vault's tier.
     */
    function getVaultTierConfig(address vaultAddress) external view returns (TierConfig memory);

    /**
     * @dev Calculates the performance fee for a given reward amount.
     * @param vaultAddress The address of the vault.
     * @param rewardAmount The total reward amount.
     * @return The calculated performance fee amount.
     */
    function calculatePerformanceFee(address vaultAddress, uint256 rewardAmount) external view returns (uint256);

    /**
     * @dev Calculates how a deposit fee is split between the platform and the vault admin.
     * @param vaultAddress The address of the vault.
     * @param feeAmount The total fee amount to be split.
     * @return platformShare The portion of the fee for the platform.
     * @return adminShare The portion of the fee for the vault admin.
     */
    function calculateDepositFeeSharing(address vaultAddress, uint256 feeAmount) external view returns (uint256 platformShare, uint256 adminShare);
    
    /**
     * @dev Upgrades a vault to a new tier.
     * @param vaultAddress The address of the vault to upgrade.
     * @param newTier The target tier to upgrade to.
     */
    function upgradeVaultTier(address vaultAddress, VaultTier newTier) external payable;

    /**
     * @dev Returns the current tier of a specific vault.
     * @param vaultAddress The address of the vault.
     * @return The current tier of the vault.
     */
    function getVaultTier(address vaultAddress) external view returns (VaultTier);
}