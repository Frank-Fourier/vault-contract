// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVault {
    struct NFTLock {
        address collection;
        uint256 tokenId;
    }

    struct NFTCollectionRequirement {
        bool isActive;
        uint256 requiredCount;
        uint256 boostPercentage;
    }

    enum VaultTier {
        NO_RISK_NO_CROWN,
        SPLIT_THE_SPOILS,
        VAULTMASTER_3000
    }

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

    function userCumulativeVotingPower(address _user) external view returns (uint256);

    function userEpochContributed(address _user, uint256 _epochId) external view returns (bool);

    function nftCollectionRequirements(address) external view returns (NFTCollectionRequirement memory);

    function getUserNFTCountForCollection(address _user, address _collection) external view returns (uint256);
}

/**
 * @title VaultReader
 * @dev A separate, read-only contract for fetching data from a Vault.
 *      This reduces the size of the main Vault contract and provides a simple interface for UIs.
 */
contract VaultReader {
    IVault public immutable vault;

    constructor(address _vaultAddress) {
        require(_vaultAddress != address(0), "VR.1");
        vault = IVault(_vaultAddress);
    }

    /**
     * @dev Returns the locked NFTs for a user.
     * @param _user Address of the user.
     * @return The array of locked NFTs for the user.
     */
    function getUserNFTs(address _user) external view returns (IVault.NFTLock[] memory) {
        (,,,, , IVault.NFTLock[] memory lockedNFTs) = vault.getUserInfo(_user);
        return lockedNFTs;
    }

    /**
     * @dev Returns the count of locked NFTs for a user.
     * @param _user Address of the user.
     * @return The count of locked NFTs for the user.
     */
    function getUserNFTCount(address _user) external view returns (uint256) {
        (,,,, , IVault.NFTLock[] memory lockedNFTs) = vault.getUserInfo(_user);
        return lockedNFTs.length;
    }

    /**
     * @dev Gets the total reward amounts (regular + leaderboard) for an epoch.
     * @param _epochId Epoch ID.
     * @return rewardTokens Array of reward token addresses.
     * @return totalAmounts Array of total amounts.
     */
    function getTotalEpochRewards(uint256 _epochId) 
        external 
        view 
        returns (address[] memory rewardTokens, uint256[] memory totalAmounts) 
    {
        (,,, address[] memory _rewardTokens, uint256[] memory rewardAmounts, uint256[] memory leaderboardBonusAmounts,,) = vault.getEpochInfo(_epochId);
        
        totalAmounts = new uint256[](rewardAmounts.length);
        
        for (uint256 i = 0; i < rewardAmounts.length; i++) {
            totalAmounts[i] = rewardAmounts[i] + leaderboardBonusAmounts[i];
        }
        
        return (_rewardTokens, totalAmounts);
    }

    /**
     * @dev Gets the leaderboard bonus amounts for an epoch.
     * @param _epochId Epoch ID.
     * @return rewardTokens Array of reward token addresses.
     * @return bonusAmounts Array of bonus amounts.
     */
    function getLeaderboardBonusAmounts(uint256 _epochId) 
        external 
        view 
        returns (address[] memory rewardTokens, uint256[] memory bonusAmounts) 
    {
        (,,, rewardTokens, , bonusAmounts,,) = vault.getEpochInfo(_epochId);
        return (rewardTokens, bonusAmounts);
    }

    /**
     * @dev Gets a user's cumulative voting power across all epochs.
     * @param _user Address of the user.
     * @return cumulativePower User's total cumulative voting power.
     */
    function getUserCumulativeVotingPower(address _user) external view returns (uint256) {
        return vault.userCumulativeVotingPower(_user);
    }

    /**
     * @dev Checks if a user has contributed to a specific epoch (for cumulative tracking).
     * @param _user Address of the user.
     * @param _epochId Epoch ID to check.
     * @return contributed Whether the user has contributed to this epoch.
     */
    function hasUserContributedToEpoch(address _user, uint256 _epochId) external view returns (bool) {
        return vault.userEpochContributed(_user, _epochId);
    }

    /**
     * @dev Checks if a user qualifies for NFT perks from a specific collection.
     * @param _user Address of the user.
     * @param _collection Address of the NFT collection.
     * @return qualifies Whether the user qualifies for the perk.
     * @return boostPercentage The boost percentage they get.
     */
    function doesUserQualifyForNFTPerk(address _user, address _collection) 
        external 
        view 
        returns (bool qualifies, uint256 boostPercentage) 
    {
        IVault.NFTCollectionRequirement memory requirement = vault.nftCollectionRequirements(_collection);
        
        if (!requirement.isActive) {
            return (false, 0);
        }
        
        uint256 userNFTCount = vault.getUserNFTCountForCollection(_user, _collection);
        qualifies = userNFTCount >= requirement.requiredCount;
        boostPercentage = qualifies ? requirement.boostPercentage : 0;
        
        return (qualifies, boostPercentage);
    }
}
