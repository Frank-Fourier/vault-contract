// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IVaultFactory.sol";

/**
 * @title IVault
 * @dev Interface for the main Vault contract, defining its external-facing functions.
 */
interface IVault {
    /**
     * @dev Represents a locked NFT.
     * @param collection The address of the NFT collection.
     * @param tokenId The ID of the locked NFT.
     */
    struct NFTLock {
        address collection;
        uint256 tokenId;
    }

    /**
     * @dev Represents the requirements for an NFT collection to provide a boost.
     * @param isActive Whether the collection is currently accepted for boosts.
     * @param requiredCount The number of NFTs from the collection required for the boost.
     * @param boostPercentage The percentage boost granted, in basis points.
     */
    struct NFTCollectionRequirement {
        bool isActive;
        uint256 requiredCount;
        uint256 boostPercentage;
    }

    /**
     * @dev Initializes the vault. Can only be called once.
     * @param _token The address of the ERC20 token to be locked.
     * @param _depositFeeRate The initial deposit fee rate in basis points.
     * @param _vaultAdmin The address of the vault's administrator.
     * @param _factory The address of the VaultFactory that created this vault.
     * @param _feeBeneficiary The address that receives the admin's share of deposit fees.
     * @param _tier The tier of this vault.
     */
    function initialize(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory,
        address _feeBeneficiary,
        IVaultFactory.VaultTier _tier
    ) external;

    /**
     * @dev Returns the owner (admin) of the vault.
     * @return The address of the owner.
     */
    function owner() external view returns (address);

    /**
     * @dev Updates the vault's tier. Only callable by the factory.
     * @param _newTier The new tier to set for the vault.
     */
    function updateVaultTier(IVaultFactory.VaultTier _newTier) external;

    /**
     * @dev Retrieves all lock information for a specific user.
     * @param _user The address of the user.
     * @return amount The total amount of tokens locked.
     * @return lockStart The timestamp when the lock began.
     * @return lockEnd The timestamp when the lock will end.
     * @return peakVotingPower The user's maximum voting power at the time of deposit/extension.
     * @return epochsToClaim An array of epoch IDs from which the user can claim rewards.
     * @return lockedNFTs An array of NFTs locked by the user.
     */
    function getUserInfo(address _user)
        external
        view
        returns (
            uint256 amount,
            uint256 lockStart,
            uint256 lockEnd,
            uint256 peakVotingPower,
            uint256[] memory epochsToClaim,
            NFTLock[] memory lockedNFTs
        );

    /**
     * @dev Retrieves all information for a specific epoch.
     * @param _epochId The ID of the epoch.
     * @return startTime The timestamp when the epoch began.
     * @return endTime The timestamp when the epoch will end.
     * @return totalVotingPower The total aggregated voting power in the epoch.
     * @return rewardTokens An array of reward token addresses.
     * @return rewardAmounts An array of corresponding reward token amounts.
     * @return leaderboardBonusAmounts An array of corresponding leaderboard bonus amounts.
     * @return leaderboardPercentage The percentage of rewards allocated to the leaderboard.
     * @return leaderboardClaimed A boolean indicating if the leaderboard bonus has been claimed.
     */
    function getEpochInfo(uint256 _epochId)
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 totalVotingPower,
            address[] memory rewardTokens,
            uint256[] memory rewardAmounts,
            uint256[] memory leaderboardBonusAmounts,
            uint256 leaderboardPercentage,
            bool leaderboardClaimed
        );

    /**
     * @dev Returns a user's cumulative voting power across all epochs.
     * @param _user The address of the user.
     * @return The user's total cumulative voting power.
     */
    function userCumulativeVotingPower(address _user) external view returns (uint256);

    /**
     * @dev Checks if a user's power from an epoch has been contributed to the leaderboard.
     * @param _user The address of the user.
     * @param _epochId The ID of the epoch.
     * @return True if the user has contributed power from this epoch, false otherwise.
     */
    function userEpochContributed(address _user, uint256 _epochId) external view returns (bool);

    /**
     * @dev Returns the boost requirements for a specific NFT collection.
     * @param _collection The address of the NFT collection.
     * @return The NFT collection requirement configuration.
     */
    function nftCollectionRequirements(address _collection) external view returns (NFTCollectionRequirement memory);

    /**
     * @dev Returns the address of the current top holder in the cumulative leaderboard.
     * @return The address of the top holder.
     */
    function vaultTopHolder() external view returns (address);

    /**
     * @dev Returns the cumulative voting power of the top holder.
     * @return The top holder's cumulative power.
     */
    function vaultTopHolderCumulativePower() external view returns (uint256);
    
    /**
     * @dev Returns the number of NFTs a user has locked from a specific collection.
     * @param user The address of the user.
     * @param collection The address of the NFT collection.
     * @return The count of locked NFTs from that collection for the user.
     */
    function userNFTCounts(address user, address collection) external view returns (uint256);
}