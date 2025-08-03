// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVault {
    struct NFTLock {
        address collection;
        uint256 tokenId;
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

    function getEpochCount() external view returns (uint256);

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

    function getVaultLeaderboard(address _user)
        external
        view
        returns (
            address topHolder,
            uint256 topHolderCumulativePower,
            uint256 userRank,
            uint256 userCumulativePower
        );

    function userCumulativeVotingPower(address _user) external view returns (uint256);

    function userEpochContributed(address _user, uint256 _epochId) external view returns (bool);
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
     * @dev Returns the user information including locked NFTs.
     * @param _user Address of the user.
     * @return amount The amount of tokens locked.
     * @return lockStart The timestamp when the lock started.
     * @return lockEnd The timestamp when the lock ends.
     * @return peakVotingPower The peak voting power of the user.
     * @return epochsToClaim The epochs the user can claim rewards from.
     * @return lockedNFTs The array of locked NFTs.
     */
    function getUserInfo(
        address _user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 lockStart,
            uint256 lockEnd,
            uint256 peakVotingPower,
            uint256[] memory epochsToClaim,
            IVault.NFTLock[] memory lockedNFTs
        )
    {
        return vault.getUserInfo(_user);
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
     * @dev Returns the number of epochs.
     * @return The total number of epochs.
     */
    function getEpochCount() external view returns (uint256) {
        return vault.getEpochCount();
    }

    /**
     * @dev Returns details of a specific epoch including leaderboard info.
     * @param _epochId Epoch ID.
     * @return startTime The start time of the epoch.
     * @return endTime The end time of the epoch.
     * @return totalVotingPower The total voting power in the epoch.
     * @return rewardTokens The reward tokens for the epoch.
     * @return rewardAmounts The reward amounts for the epoch.
     * @return leaderboardBonusAmounts The leaderboard bonus amounts.
     * @return leaderboardPercentage The leaderboard percentage.
     * @return leaderboardClaimed Whether the leaderboard bonus has been claimed.
     */
    function getEpochInfo(
        uint256 _epochId
    )
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
        )
    {
        return vault.getEpochInfo(_epochId);
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
        return vault.getVaultLeaderboard(_user);
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
}
