// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IVaultFactory.sol";

interface IVault {
    function initialize(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory,
        address _feeBeneficiary,
        IVaultFactory.VaultTier _tier
    ) external;

    // Structs and Enums needed by consumers
    struct NFTLock {
        address collection;
        uint256 tokenId;
    }

    struct NFTCollectionRequirement {
        bool isActive;
        uint256 requiredCount;
        uint256 boostPercentage;
    }

    // Functions needed by VaultFactory
    function owner() external view returns (address);
    function updateVaultTier(IVaultFactory.VaultTier _newTier) external;

    // Functions needed by VaultReader
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

    function nftCollectionRequirements(address _collection) external view returns (NFTCollectionRequirement memory);

    function vaultTopHolder() external view returns (address);

    function vaultTopHolderCumulativePower() external view returns (uint256);

    function userNFTCounts(address user, address collection) external view returns (uint256);
}