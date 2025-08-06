// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IVault.sol";

/**
 * @title VaultReader
 * @dev A separate, read-only contract for fetching data from a Vault.
 *      This reduces the size of the main Vault contract and provides a simple interface for UIs.
 */
contract VaultReader {
    IVault public immutable vault;

    constructor(address _vaultAddress) {
        require(_vaultAddress != address(0), "V.R.: invalid vault address");
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
     * @dev Gets current vault leaderboard info (cumulative across epochs).
     * @param _user Address of the user to check ranking for.
     * @return topHolder Address of current vault top holder.
     * @return topHolderCumulativePower Current top holder's cumulative voting power.
     * @return userRank User's current rank (1 = top, 0 = not participating).
     * @return userCumulativePower User's cumulative voting power across all epochs.
     */
    function getVaultLeaderboard(address _user)
        external
        view
        returns (
            address topHolder,
            uint256 topHolderCumulativePower,
            uint256 userRank,
            uint256 userCumulativePower
        )
    {
        topHolder = vault.vaultTopHolder();
        topHolderCumulativePower = vault.vaultTopHolderCumulativePower();
        userCumulativePower = vault.userCumulativeVotingPower(_user);

        // Calculate user rank (simplified - just check if user is top holder)
        uint256 rank = 0;
        if (userCumulativePower > 0) {
            if (_user == topHolder) {
                rank = 1;
            } else {
                rank = 2; // For simplicity, everyone else is rank 2+
            }
        }

        return (
            topHolder,
            topHolderCumulativePower,
            rank,
            userCumulativePower
        );
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
        
        uint256 userNFTCount = getUserNFTCountForCollection(_user, _collection);
        qualifies = userNFTCount >= requirement.requiredCount;
        boostPercentage = qualifies ? requirement.boostPercentage : 0;
        
        return (qualifies, boostPercentage);
    }

    /**
     * @dev Gets the count of NFTs for a specific collection that a user has locked.
     *      This is the efficient implementation that reads directly from the Vault's public mapping.
     * @param _user Address of the user.
     * @param _collection Address of the NFT collection.
     * @return count Number of NFTs from the collection.
     */
    function getUserNFTCountForCollection(address _user, address _collection) public view returns (uint256) {
        return vault.userNFTCounts(_user, _collection);
    }
}
