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

    function mainFeeBeneficiary() external view returns (address);
    function getVaultTierConfig(address vaultAddress) external view returns (TierConfig memory);
    function calculatePerformanceFee(address vaultAddress, uint256 rewardAmount) external view returns (uint256);
    function calculateDepositFeeSharing(address vaultAddress, uint256 feeAmount) external view returns (uint256 platformShare, uint256 adminShare);
    function upgradeVaultTier(address vaultAddress, VaultTier newTier) external payable;
    function getVaultTier(address vaultAddress) external view returns (VaultTier);
}