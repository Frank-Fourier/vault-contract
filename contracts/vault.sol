// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}

interface IVaultFactory {
    enum VaultTier {
        NO_RISK_NO_CROWN,    // 0: Free deployment, 10% performance, 5% deposit
        SPLIT_THE_SPOILS,    // 1: 0.1 ETH deployment, 5% performance, 1-10% deposit (50% shared)
        VAULTMASTER_3000     // 2: 2 ETH deployment, 1.5% performance, 0-10% deposit (admin keeps 100%)
    }

    struct TierConfig {
        uint256 deploymentFee;           // Deployment fee in wei
        uint256 performanceFeeRate;      // Performance fee in basis points
        uint256 minDepositFeeRate;       // Minimum deposit fee in basis points
        uint256 maxDepositFeeRate;       // Maximum deposit fee in basis points
        uint256 platformDepositShare;    // Platform share of deposit fees in basis points (10000 = 100%)
        bool    canAdjustDepositFee;     // Whether admin can adjust deposit fee
        string  tierName;                // Human readable tier name
    }

    function mainFeeBeneficiary() external view returns (address);
    function getVaultTierConfig(address vaultAddress) external view returns (TierConfig memory);
    function calculatePerformanceFee(address vaultAddress, uint256 rewardAmount) external view returns (uint256);
    function calculateDepositFeeSharing(address vaultAddress, uint256 feeAmount) external view returns (uint256 platformShare, uint256 adminShare);
    function upgradeVaultTier(address vaultAddress, VaultTier newTier) external payable;
    function getVaultTier(address vaultAddress) external view returns (VaultTier);
}

/**
 * @title Vault
 * @dev A contract that locks user tokens for a specified duration and provides linear decaying voting power.
 *      Users can participate in epochs to earn rewards distributed proportionally to their voting power.
 */
contract Vault is ReentrancyGuard, IERC721Receiver {
    IERC20 public immutable token;
    IVaultFactory public immutable factory;

    /// @notice Define an admin for this vault:
    address public vaultAdmin;

    /// @notice Fee beneficiary address
    address public feeBeneficiaryAddress;

    /// @notice The deposit fee rate in basis points (e.g. 100 = 1%)
    uint256 public depositFeeRate;

    /// @notice Maximum fee rate allowed in basis points (e.g., 2000 = 20%)
    uint256 public constant MAX_FEE_RATE = 2000; // Maximum fee rate in basis points (e.g., 2000 = 20%)

    /// @notice Max Epoch Duration
    uint256 public constant MAX_EPOCH_DURATION = 8 weeks;

    /// @notice Minimum duration for an epoch
    uint256 public constant MIN_EPOCH_DURATION = 1 weeks;

    /// @notice Minimum amount of tokens required to lock
    uint256 public constant MIN_LOCK_AMOUNT = 1_000 * 10 ** 18;

    /// @notice Maximum duration for which tokens can be locked (52 weeks)
    uint256 public constant MAX_LOCK_DURATION = 52 weeks;

    /// @notice Minimum duration for which tokens can be locked (1 week)
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;

    /// @notice Variable to track the current epoch ID
    uint256 public currentEpochId;

    /// @notice State variable to track if the vault is paused
    bool public paused = false;

    /// @notice State variable to track if emergency withdraw is enabled
    bool public emergencyWithdrawEnabled;

    /// @notice The tier of this vault
    IVaultFactory.VaultTier public vaultTier;

    struct NFTLock {
        address collection; // NFT collection address
        uint256 tokenId;   // NFT token ID
    }

    struct UserLock {
        uint256 amount; // Total tokens locked.
        uint256 lockStart; // Timestamp when lock started.
        uint256 lockEnd; // Timestamp when lock ends.
        uint256 peakVotingPower; // Max voting power at deposit/extension.
        uint256[] epochsToClaim; // Epochs the user can claim rewards from.
        NFTLock[] lockedNFTs; // Array of locked NFTs
    }

    struct Epoch {
        uint256 startTime; // Epoch start time.
        uint256 endTime; // Epoch end time.
        uint256 totalVotingPower; // Total voting power in this epoch.
        address[] rewardTokens; // List of reward tokens.
        uint256[] rewardAmounts; // Corresponding reward amounts
        uint256[] leaderboardBonusAmounts; // Leaderboard bonus amounts
        uint256 leaderboardPercentage; // Percentage of rewards for top holder (basis points)
        bool leaderboardClaimed; // Whether leaderboard bonus has been claimed
    }

    /// @notice Mapping to store user locks based on their address
    mapping(address => UserLock) private userLocks;

    /// @notice Mapping to store user's voting power in each epoch
    mapping(address => mapping(uint256 => uint256)) public userEpochVotingPower;

    /// @notice Array to store all epochs
    Epoch[] public epochs;

    /// @notice Event emitted when tokens are deposited into the vault.
    /// @param user The address of the user who deposited the tokens.
    /// @param amount The amount of tokens deposited.
    /// @param fee The fee charged for the deposit.
    event Deposited(address indexed user, uint256 amount, uint256 fee);

    /// @notice Event emitted when a user's lock is extended.
    /// @param user The address of the user who extended the lock.
    /// @param newAmount The new total amount of tokens locked.
    /// @param newLockEnd The new lock end time.
    event ExtendedLock(
        address indexed user,
        uint256 newAmount,
        uint256 newLockEnd
    );

    /// @notice Event emitted when tokens are withdrawn from the vault.
    /// @param user The address of the user who withdrew the tokens.
    /// @param amount The amount of tokens withdrawn.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Event emitted when a new epoch is started.
    /// @param epochId The ID of the new epoch.
    /// @param rewardTokens The list of reward tokens for the epoch.
    /// @param rewardAmounts The corresponding reward amounts for the epoch.
    /// @param endTime The end time of the epoch.
    event EpochStarted(
        uint256 indexed epochId,
        address[] rewardTokens,
        uint256[] rewardAmounts,
        uint256 endTime
    );

    /// @notice Event emitted when rewards are claimed by a user.
    /// @param user The address of the user who claimed the rewards.
    /// @param epochId The ID of the epoch from which rewards were claimed.
    event RewardsClaimed(address indexed user, uint256 indexed epochId);

    /// @notice Event emitted when a user participates in an epoch.
    /// @param user The address of the user who participated.
    /// @param epochId The ID of the epoch in which the user participated.
    /// @param votingPower The voting power of the user in the epoch.
    event Participated(
        address indexed user,
        uint256 indexed epochId,
        uint256 votingPower
    );

    /// @notice Event emitted when vault admin is changed.
    /// @param oldAdmin The address of the previous admin.
    /// @param newAdmin The address of the new admin.
    event VaultAdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Event emitted when fee rate is updated.
    /// @param oldRate The previous fee rate in basis points.
    /// @param newRate The new fee rate in basis points.
    event DepositFeeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Event emitted when fee beneficiary is updated.
    /// @param oldBeneficiary The address of the previous fee beneficiary.
    /// @param newBeneficiary The address of the new fee beneficiary.
    event FeeBeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );

    /// @notice Event emitted when vault is paused or unpaused.
    /// @param isPaused A boolean indicating the current status of the vault; true if paused, false if unpaused.
    event VaultStatusChanged(bool isPaused);

    /// @notice Event emitted when emergency withdraw is enabled.
    /// @param enabledBy The address of the admin who enabled emergency withdrawal.
    event EmergencyWithdrawEnabled(address indexed enabledBy);

    /// @notice Event emitted when emergency withdrawal of other tokens occurs.
    /// @param token The address of the token being withdrawn.
    /// @param amount The amount of tokens withdrawn.
    event EmergencyTokenWithdraw(address indexed token, uint256 amount);

    /// @notice Event emitted when emergency withdrawal of locked tokens occurs.
    /// @param user The address of the user withdrawing their locked tokens.
    /// @param amount The amount of locked tokens withdrawn.
    event EmergencyPrincipalWithdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when additional rewards are added to an epoch.
    /// @param epochId The ID of the epoch rewards were added to.
    /// @param rewardTokens The additional reward tokens added.
    /// @param rewardAmounts The additional reward amounts added.
    event RewardsAddedToEpoch(
        uint256 indexed epochId,
        address[] rewardTokens,
        uint256[] rewardAmounts
    );

    /// @notice Event emitted when an NFT is deposited into the vault.
    /// @param user The address of the user who deposited the NFT.
    /// @param collection The address of the NFT collection.
    /// @param tokenId The token ID of the deposited NFT.
    event NFTDeposited(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @notice Event emitted when an NFT is withdrawn from the vault.
    /// @param user The address of the user who withdrew the NFT.
    /// @param collection The address of the NFT collection.
    /// @param tokenId The token ID of the withdrawn NFT.
    event NFTWithdrawn(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @notice Event emitted when emergency withdrawal of NFTs occurs.
    /// @param user The address of the user withdrawing their locked NFTs.
    /// @param collection The address of the NFT collection.
    /// @param tokenId The token ID of the emergency withdrawn NFT.
    event EmergencyNFTWithdraw(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @notice Event emitted when NFT collection requirement is set.
    /// @param collection The address of the NFT collection.
    /// @param isActive Whether the collection is active.
    /// @param requiredCount The number of NFTs required.
    /// @param boostPercentage The boost percentage in basis points.
    event NFTCollectionRequirementSet(
        address indexed collection, 
        bool isActive, 
        uint256 requiredCount, 
        uint256 boostPercentage
    );

    /// @notice Add after existing structs (MISSING from current contract)
    struct NFTCollectionRequirement {
        bool isActive; // Whether this collection is accepted
        uint256 requiredCount; // How many NFTs needed for the perk
        uint256 boostPercentage; // Boost percentage in basis points (e.g., 500 = 5%)
    }

    /// @notice Add after existing mappings (MISSING from current contract)
    /// @notice Mapping to store NFT collection requirements and boosts
    mapping(address => NFTCollectionRequirement) public nftCollectionRequirements;

    /// @notice Maximum number of NFTs a user can lock (gas protection)
    uint256 public constant MAX_NFTS_PER_USER = 50;

    /// @notice Event emitted when a new vault top holder is set (cumulative)
    event NewVaultTopHolder(
        address indexed newTopHolder, 
        address indexed previousTopHolder,
        uint256 cumulativePower
    );

    /// @notice Event emitted when leaderboard bonus is claimed
    event LeaderboardBonusClaimed(
        uint256 indexed epochId,
        address indexed topHolder,
        uint256 cumulativePower,
        address[] rewardTokens,
        uint256[] bonusAmounts
    );

    /// @notice Current top holder across all epochs (cumulative)
    address public vaultTopHolder;

    /// @notice Top holder's cumulative voting power across all epochs
    uint256 public vaultTopHolderCumulativePower;

    /// @notice Mapping to track cumulative voting power per user across all epochs
    mapping(address => uint256) public userCumulativeVotingPower;

    /// @notice Track which epochs each user has contributed their cumulative power to (prevent double-counting)
    mapping(address => mapping(uint256 => bool)) public userEpochContributed;

    /**
     * @dev Modifier to make a function callable only by the vault admin.
     */
    modifier onlyVaultAdmin() {
        require(msg.sender == vaultAdmin, "Vault: Not vault admin");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     */
    modifier whenNotPaused() {
        require(!paused, "Vault: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     */
    modifier whenPaused() {
        require(paused, "Vault: not paused");
        _;
    }

    /*
     * ==========  CONSTRUCTOR  ==========
     */

    /**
     * @dev Initializes the vault with necessary parameters.
     * @param _token Address of the ERC20 token to lock.
     * @param _depositFeeRate Fee rate in basis points (e.g., 100 = 1%).
     * @param _vaultAdmin Admin address for the vault.
     * @param _factory Address of the VaultFactory.
     * @param _feeBeneficiary Address for fee distribution.
     * @param _tier The tier of this vault
     */
    constructor(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory,
        address _feeBeneficiary,
        IVaultFactory.VaultTier _tier
    ) {
        require(_token != address(0), "Vault: invalid token");
        require(_vaultAdmin != address(0), "Vault: invalid admin");
        require(_factory != address(0), "Vault: invalid factory");
        require(_feeBeneficiary != address(0), "Vault: invalid beneficiary");
        require(_depositFeeRate <= MAX_FEE_RATE, "Vault: fee rate too high");

        token = IERC20(_token);
        depositFeeRate = _depositFeeRate;
        vaultAdmin = _vaultAdmin;
        factory = IVaultFactory(_factory);
        feeBeneficiaryAddress = _feeBeneficiary;
        vaultTier = _tier;
    }

    /**
     * @dev Handle the receipt of an NFT
     * @param operator The address which called `safeTransferFrom` function
     * @param from The address which previously owned the token
     * @param tokenId The NFT identifier which is being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*
     * ==========  MAIN FUNCTIONS  ==========
     */

    /**
     * @dev Deposits tokens into the vault and locks them for the specified duration.
     * @param _amount Amount of tokens to deposit.
     * @param _duration Lock duration in seconds.
     */
    function deposit(
        uint256 _amount,
        uint256 _duration
    ) external nonReentrant whenNotPaused {
        require(_amount >= MIN_LOCK_AMOUNT, "Vault: amount too small");
        require(
            _duration >= MIN_LOCK_DURATION && _duration <= MAX_LOCK_DURATION,
            "Vault: invalid duration"
        );

        uint256 fee = (_amount * depositFeeRate) / 10000;
        uint256 netAmount = _amount - fee;

        require(
            token.allowance(msg.sender, address(this)) >= _amount,
            "Vault: insufficient allowance"
        );
        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "Vault: transfer failed"
        );
        
        if (fee > 0) {
            // Use tier-based fee sharing
            (uint256 platformShare, uint256 adminShare) = factory.calculateDepositFeeSharing(address(this), fee);
            
            if (platformShare > 0) {
                require(token.transfer(factory.mainFeeBeneficiary(), platformShare), "Vault: platform fee transfer failed");
            }
            if (adminShare > 0) {
                require(token.transfer(feeBeneficiaryAddress, adminShare), "Vault: admin fee transfer failed");
            }
        }

        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount == 0, "Vault: lock already active");

        lock.amount = netAmount;
        lock.lockStart = block.timestamp;
        lock.lockEnd = block.timestamp + _duration;
        lock.peakVotingPower = netAmount;

        _updateUserEpochPower(msg.sender);
        emit Deposited(msg.sender, _amount, fee);
    }

    /**
     * @dev Extend lock time or add more tokens.
     *      newLockEnd > current lockEnd if we want a time extension,
     *      or addAmount > 0 to lock more tokens.
     * @param _additionalAmount Amount of tokens to deposit.
     * @param _duration Lock duration in seconds.
     */
    function expandLock(
        uint256 _additionalAmount,
        uint256 _duration
    ) external nonReentrant whenNotPaused {
        require(
            _additionalAmount > 0 || _duration > 0,
            "Vault: either one should be positive"
        );

        if (_additionalAmount > 0) {
            uint256 fee = (_additionalAmount * depositFeeRate) / 10000;
            uint256 netAmount = _additionalAmount - fee;

            require(
                token.allowance(msg.sender, address(this)) >= _additionalAmount,
                "Vault: insufficient allowance"
            );
            require(
                token.transferFrom(msg.sender, address(this), _additionalAmount),
                "Vault: transfer failed"
            );
            
            if (fee > 0) {
                // Use tier-based fee sharing
                (uint256 platformShare, uint256 adminShare) = factory.calculateDepositFeeSharing(address(this), fee);
                
                if (platformShare > 0) {
                    require(token.transfer(factory.mainFeeBeneficiary(), platformShare), "Vault: platform fee transfer failed");
                }
                if (adminShare > 0) {
                    require(token.transfer(feeBeneficiaryAddress, adminShare), "Vault: admin fee transfer failed");
                }
            }

            _expandLock(
                msg.sender,
                netAmount,
                _duration == 0 ? 0 : block.timestamp + _duration
            );
        } else {
            // purely extend lock time
            _expandLock(msg.sender, 0, block.timestamp + _duration);
        }

        // Update user's epoch contribution if there's an active epoch
        _updateUserEpochPower(msg.sender);
    }

    /**
     * @dev Withdraws tokens from the vault after the lock period has ended.
     */
    function withdraw() external nonReentrant whenNotPaused {
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: no active lock");
        require(block.timestamp >= lock.lockEnd, "Vault: lock not ended");

        uint256 withdrawable = lock.amount;
        _reduceUserEpochPower(msg.sender);

        // Transfer all locked NFTs back to user
        uint256 nftCount = lock.lockedNFTs.length;
        for (uint256 i = 0; i < nftCount; i++) {
            NFTLock memory nftLock = lock.lockedNFTs[i];
            IERC721(nftLock.collection).safeTransferFrom(address(this), msg.sender, nftLock.tokenId);
            emit NFTWithdrawn(msg.sender, nftLock.collection, nftLock.tokenId);
        }

        // Clear user lock data
        lock.amount = 0;
        lock.lockEnd = 0;
        lock.lockStart = 0;
        lock.peakVotingPower = 0;
        delete lock.lockedNFTs;

        require(
            token.transfer(msg.sender, withdrawable),
            "Vault: transfer failed"
        );
        emit Withdrawn(msg.sender, withdrawable);
    }

    /**
     * @dev Allow the user with an active lock and voting power to take part in an epoch.
     *      The median voting power from the effective start time to the effective end time
     *      is added to the total epoch voting power and registered to the user epoch voting power.
     */
    function participate() external whenNotPaused {
        if (epochs.length == 0) return;
        Epoch storage epoch = epochs[currentEpochId];
        UserLock storage lockData = userLocks[msg.sender];
        require(lockData.amount > 0, "Vault: no active lock");
        require(block.timestamp < lockData.lockEnd, "Vault: lock has ended");
        require(block.timestamp < epoch.endTime, "Vault: epoch is ended");
        require(
            userEpochVotingPower[msg.sender][currentEpochId] == 0,
            "Vault: already registered for this epoch"
        );

        _updateUserEpochPower(msg.sender);

        emit Participated(
            msg.sender,
            currentEpochId,
            userEpochVotingPower[msg.sender][currentEpochId]
        );
    }

    /*
     * ==========  NFT FUNCTIONS  ==========
     */

    /**
     * @dev Deposits an NFT into the vault alongside existing token lock.
     * @param _collection Address of the NFT collection.
     * @param _tokenId Token ID of the NFT to deposit.
     */
    function depositNFT(address _collection, uint256 _tokenId) external nonReentrant whenNotPaused {
        require(_collection != address(0), "Vault: invalid collection address");
        
        NFTCollectionRequirement memory requirement = nftCollectionRequirements[_collection];
        // Allow deposits even if no requirement is set, but if requirement exists, it must be active
        if (requirement.requiredCount > 0 || requirement.boostPercentage > 0) {
            require(requirement.isActive, "Vault: collection not allowed");
        }
        
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: must have active token lock first");
        require(block.timestamp < lock.lockEnd, "Vault: token lock has expired");
        
        // Verify ownership and get approval
        IERC721 nftContract = IERC721(_collection);
        require(nftContract.ownerOf(_tokenId) == msg.sender, "Vault: not NFT owner");
        require(
            nftContract.getApproved(_tokenId) == address(this) || 
            nftContract.isApprovedForAll(msg.sender, address(this)),
            "Vault: NFT not approved"
        );
        
        // Check if NFT is already locked by this user
        uint256 nftCount = lock.lockedNFTs.length;
        for (uint256 i = 0; i < nftCount; i++) {
            require(
                !(lock.lockedNFTs[i].collection == _collection && lock.lockedNFTs[i].tokenId == _tokenId),
                "Vault: NFT already locked"
            );
        }
        
        // Transfer NFT to vault
        nftContract.safeTransferFrom(msg.sender, address(this), _tokenId);
        
        // Add NFT to user's lock
        lock.lockedNFTs.push(NFTLock({
            collection: _collection,
            tokenId: _tokenId
        }));
        
        // Update user's epoch power to account for potential NFT boost
        _updateUserEpochPower(msg.sender); //TO CHECK IF THIS IS CORRECT
        
        emit NFTDeposited(msg.sender, _collection, _tokenId);
    }

    /**
     * @dev Withdraws a specific NFT from the vault.
     * @param _collection Address of the NFT collection.
     * @param _tokenId Token ID of the NFT to withdraw.
     */
    function withdrawNFT(address _collection, uint256 _tokenId) external nonReentrant whenNotPaused {
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: no active lock");
        require(block.timestamp >= lock.lockEnd, "Vault: lock not ended");
        
        // Find and remove the NFT from user's locked NFTs
        uint256 nftCount = lock.lockedNFTs.length;
        bool nftFound = false;
        
        for (uint256 i = 0; i < nftCount; i++) {
            if (lock.lockedNFTs[i].collection == _collection && lock.lockedNFTs[i].tokenId == _tokenId) {
                // Transfer NFT back to user
                IERC721(_collection).safeTransferFrom(address(this), msg.sender, _tokenId);
                
                // Remove NFT from array by swapping with last element and popping
                lock.lockedNFTs[i] = lock.lockedNFTs[nftCount - 1];
                lock.lockedNFTs.pop();
                
                nftFound = true;
                emit NFTWithdrawn(msg.sender, _collection, _tokenId);
                break;
            }
        }
        
        require(nftFound, "Vault: NFT not found in user's lock");
    }

    /**
     * @dev Withdraws all NFTs when withdrawing tokens.
     */
    function withdrawAllNFTs() external nonReentrant whenNotPaused {
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: no active lock");
        require(block.timestamp >= lock.lockEnd, "Vault: lock not ended");
        
        // Transfer all locked NFTs back to user
        uint256 nftCount = lock.lockedNFTs.length;
        for (uint256 i = 0; i < nftCount; i++) {
            NFTLock memory nftLock = lock.lockedNFTs[i];
            IERC721(nftLock.collection).safeTransferFrom(address(this), msg.sender, nftLock.tokenId);
            emit NFTWithdrawn(msg.sender, nftLock.collection, nftLock.tokenId);
        }
        
        // Clear the NFT array
        delete lock.lockedNFTs;
    }

    /*
     * ==========  AUXILIARY  ==========
     */

    /**
     * @dev Internal function to expand the lock of a user.
     * @param _user Address of the user.
     * @param _extraAmount Additional amount of tokens to lock.
     * @param _newEnd New lock end time. Set to 0 if not used.
     */
    function _expandLock(
        address _user,
        uint256 _extraAmount,
        uint256 _newEnd
    ) internal {
        UserLock storage lockData = userLocks[_user];
        require(lockData.amount > 0, "Vault: no existing lock");
        if (_newEnd < block.timestamp) {
            require(
                lockData.lockEnd > block.timestamp,
                "Vault: current lock expired extend it first"
            );
        }
        // Refresh current voting power
        // Then we recalc the new peakVotingPower as old leftover + new deposit
        uint256 currentVotingPower = getCurrentVotingPower(_user);

        // The new peakVotingPower can be considered as the current voting power
        // "carried forward" plus the new deposit.  For simplicity, let's just set:
        lockData.peakVotingPower = currentVotingPower + _extraAmount;

        // If user wants to set a new end time that is > oldLockEnd we set new lockEnd
        // If not, we keep the old lockEnd
        if (_newEnd > lockData.lockEnd) {
            lockData.lockEnd = _newEnd;
        }

        // set start data again using peak voting power
        lockData.lockStart = block.timestamp;

        // Increase the locked amount by the extra tokens
        if (_extraAmount > 0) {
            lockData.amount += _extraAmount;
        }

        emit ExtendedLock(_user, lockData.amount, lockData.lockEnd);
    }

    /**
     * @dev Updates user's epoch voting power for the current active epoch.
     *      Called whenever user deposits, extends, withdraws.
     *      Adjusts the vault's total voting power in that epoch as well.
     *      Also updates cumulative leaderboard stats.
     */
    function _updateUserEpochPower(address _user) internal {
        // If no active epoch, skip
        if (epochs.length == 0) return;
        UserLock storage lockData = userLocks[_user];
        Epoch storage epoch = epochs[currentEpochId];
        if (epoch.endTime <= block.timestamp) return;
        if (lockData.amount == 0) return;

        // 1. Subtract old power from epoch total
        uint256 oldUserPower = userEpochVotingPower[_user][currentEpochId];
        bool isFirstTimeInEpoch = oldUserPower == 0;

        if (oldUserPower > 0) {
            epoch.totalVotingPower = epoch.totalVotingPower > oldUserPower
                ? epoch.totalVotingPower - oldUserPower
                : 0;
        } else {
            lockData.epochsToClaim.push(currentEpochId);
        }

        uint256 effectiveStart = lockData.lockStart > epoch.startTime
            ? lockData.lockStart
            : epoch.startTime;
        uint256 effectiveEnd = lockData.lockEnd < epoch.endTime
            ? lockData.lockEnd
            : epoch.endTime;

        if (effectiveStart >= effectiveEnd) {
            userEpochVotingPower[_user][currentEpochId] = 0;
            return;
        }

        uint256 vpStart = getVotingPowerAtTime(_user, effectiveStart);
        uint256 vpEnd = getVotingPowerAtTime(_user, effectiveEnd);

        // Calculate base area under curve
        uint256 baseAreaUnderCurve = ((vpStart + vpEnd) * (effectiveEnd - effectiveStart)) / 2;
        
        // Apply NFT boost
        uint256 nftBoostPercentage = getUserNFTBoost(_user);
        uint256 boostedAreaUnderCurve = baseAreaUnderCurve;
        
        if (nftBoostPercentage > 0) {
            uint256 boostAmount = (baseAreaUnderCurve * nftBoostPercentage) / 10000;
            boostedAreaUnderCurve = baseAreaUnderCurve + boostAmount;
        }
        
        userEpochVotingPower[_user][currentEpochId] = boostedAreaUnderCurve;
        epoch.totalVotingPower += boostedAreaUnderCurve;

        // Update cumulative leaderboard stats (only once per user per epoch)
        if (isFirstTimeInEpoch && !userEpochContributed[_user][currentEpochId]) {
            userCumulativeVotingPower[_user] += boostedAreaUnderCurve;
            userEpochContributed[_user][currentEpochId] = true;
            
            // Update vault top holder if this user now has highest cumulative power
            if (userCumulativeVotingPower[_user] > vaultTopHolderCumulativePower) {
                address previousTopHolder = vaultTopHolder;
                vaultTopHolder = _user;
                vaultTopHolderCumulativePower = userCumulativeVotingPower[_user];
                
                emit NewVaultTopHolder(_user, previousTopHolder, userCumulativeVotingPower[_user]);
            }
        }
    }

    /**
     * @dev Updates user's epoch voting power for the current active epoch.
     *      Called whenever user deposits, extends, or withdraws.
     *      Adjusts the vault's total voting power in that epoch as well.
     * @param _user Address of the user whose epoch voting power is being updated.
     */
    function _reduceUserEpochPower(address _user) internal {
        // If no active epoch, skip
        if (epochs.length == 0) return;
        Epoch storage epoch = epochs[currentEpochId];
        if (epoch.endTime <= block.timestamp) return;

        UserLock storage lockData = userLocks[_user];
        if (lockData.amount == 0) return;

        // Subtract old power from epoch total
        uint256 oldUserPower = userEpochVotingPower[_user][currentEpochId];
        if (oldUserPower > 0) {
            uint256 effectiveStart = block.timestamp;
            uint256 effectiveEnd = lockData.lockEnd < epoch.endTime
                ? lockData.lockEnd
                : epoch.endTime;

            if (effectiveStart >= effectiveEnd) {
                return;
            }

            uint256 vpStart = getVotingPowerAtTime(_user, effectiveStart);
            uint256 vpEnd = getVotingPowerAtTime(_user, effectiveEnd);

            uint256 areaUnderCurve = ((vpStart + vpEnd) *
                (effectiveEnd - effectiveStart)) / 2;
            if (areaUnderCurve > oldUserPower)
                userEpochVotingPower[_user][currentEpochId] = 0;
            userEpochVotingPower[_user][currentEpochId] =
                oldUserPower -
                areaUnderCurve;
            if (areaUnderCurve > epoch.totalVotingPower)
                epoch.totalVotingPower = 0;
            epoch.totalVotingPower -= areaUnderCurve;
            if (userEpochVotingPower[_user][currentEpochId] == 0) {
                uint256 epochsToClaimLength = lockData.epochsToClaim.length;
                for (uint256 i = 0; i < epochsToClaimLength; i++) {
                    if (lockData.epochsToClaim[i] == currentEpochId) {
                        lockData.epochsToClaim[i] = lockData.epochsToClaim[
                            epochsToClaimLength - 1
                        ];
                        lockData.epochsToClaim.pop();
                        break;
                    }
                }
            }
        }
    }

    /*
     * ==========  EPOCH LOGIC  ==========
     *
     * Each epoch is started by the vault admin, specifying reward tokens and amounts.
     * Users' voting power is aggregated. When epoch ends, distribution is done.
     */

    /**
     * @dev Starts a new epoch for reward distribution with optional leaderboard.
     * @param _rewardTokens List of reward token addresses.
     * @param _rewardAmounts List of reward token amounts.
     * @param _endTime Epoch end time.
     * @param _leaderboardPercentage Percentage of rewards for top holder (basis points, 0-1000 = 0-10%).
     */
    function startEpoch(
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts,
        uint256 _endTime,
        uint256 _leaderboardPercentage
    ) external onlyVaultAdmin whenNotPaused {
        require(_rewardTokens.length == _rewardAmounts.length, "Vault: mismatched arrays");
        require(_endTime > block.timestamp, "Vault: invalid end time");
        require(
            _endTime - block.timestamp >= MIN_EPOCH_DURATION && 
            _endTime - block.timestamp <= MAX_EPOCH_DURATION,
            "Vault: invalid epoch duration"
        );
        require(_leaderboardPercentage <= 1000, "Vault: leaderboard percentage too high"); // Max 10%

        // Calculate performance fees and net amounts
        address[] memory netRewardTokens = new address[](_rewardTokens.length);
        uint256[] memory netRewardAmounts = new uint256[](_rewardAmounts.length);
        uint256[] memory leaderboardBonusAmounts = new uint256[](_rewardTokens.length);
        
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            uint256 grossAmount = _rewardAmounts[i];
            uint256 performanceFee = factory.calculatePerformanceFee(address(this), grossAmount);
            uint256 netAmount = grossAmount - performanceFee;
            
            require(IERC20(_rewardTokens[i]).allowance(msg.sender, address(this)) >= grossAmount, "Vault: insufficient allowance");
            require(IERC20(_rewardTokens[i]).transferFrom(msg.sender, address(this), grossAmount), "Vault: transfer failed");
            
            // Transfer performance fee to platform
            if (performanceFee > 0) {
                require(IERC20(_rewardTokens[i]).transfer(factory.mainFeeBeneficiary(), performanceFee), "Vault: performance fee transfer failed");
            }
            
            // Calculate leaderboard bonus upfront and separate it from regular rewards
            uint256 leaderboardBonus = (netAmount * _leaderboardPercentage) / 10000;
            uint256 regularRewardAmount = netAmount - leaderboardBonus;
            
            netRewardTokens[i] = _rewardTokens[i];
            netRewardAmounts[i] = regularRewardAmount; // Only regular rewards available for claiming
            leaderboardBonusAmounts[i] = leaderboardBonus; // Separate leaderboard bonus
        }

        if (epochs.length > 0) {
            Epoch storage prevEpoch = epochs[currentEpochId];
            require(
                prevEpoch.endTime <= block.timestamp,
                "Vault: previous epoch not ended"
            );
        }

        epochs.push(Epoch({
            startTime: block.timestamp,
            endTime: _endTime,
            totalVotingPower: 0,
            rewardTokens: netRewardTokens,
            rewardAmounts: netRewardAmounts, // Regular rewards only
            leaderboardBonusAmounts: leaderboardBonusAmounts, // Separate leaderboard pool
            leaderboardPercentage: _leaderboardPercentage,
            leaderboardClaimed: false
        }));

        currentEpochId = epochs.length - 1;
        emit EpochStarted(currentEpochId, netRewardTokens, netRewardAmounts, _endTime);
    }

    /**
     * @dev Adds additional rewards to an existing active epoch.
     * @param _epochId The ID of the epoch to add rewards to.
     * @param _rewardTokens List of additional reward token addresses.
     * @param _rewardAmounts List of additional reward token amounts.
     */
    function addRewardsToEpoch(
        uint256 _epochId,
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts
    ) external onlyVaultAdmin whenNotPaused {
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        require(
            _rewardTokens.length == _rewardAmounts.length,
            "Vault: mismatched arrays"
        );

        Epoch storage epoch = epochs[_epochId];
        require(block.timestamp < epoch.endTime, "Vault: epoch has ended");

        // Transfer the additional reward tokens and apply performance fees
        uint256 rewardTokensLength = _rewardTokens.length;
        for (uint256 i = 0; i < rewardTokensLength; i++) {
            require(
                _rewardAmounts[i] > 0,
                "Vault: reward amount must be positive"
            );
            
            uint256 grossAmount = _rewardAmounts[i];
            uint256 performanceFee = factory.calculatePerformanceFee(address(this), grossAmount);
            uint256 netAmount = grossAmount - performanceFee;
            
            require(
                IERC20(_rewardTokens[i]).allowance(msg.sender, address(this)) >= grossAmount,
                "Vault: insufficient allowance"
            );
            require(
                IERC20(_rewardTokens[i]).transferFrom(msg.sender, address(this), grossAmount),
                "Vault: transfer failed"
            );
            
            // Transfer performance fee to platform
            if (performanceFee > 0) {
                require(IERC20(_rewardTokens[i]).transfer(factory.mainFeeBeneficiary(), performanceFee), "Vault: performance fee transfer failed");
            }
            
            // Calculate leaderboard portion of additional rewards
            uint256 leaderboardBonus = (netAmount * epoch.leaderboardPercentage) / 10000;
            uint256 regularRewardAmount = netAmount - leaderboardBonus;
            
            bool tokenExists = false;
            // Check if token already exists in epoch
            for (uint256 j = 0; j < epoch.rewardTokens.length; j++) {
                if (epoch.rewardTokens[j] == _rewardTokens[i]) {
                    epoch.rewardAmounts[j] += regularRewardAmount;
                    epoch.leaderboardBonusAmounts[j] += leaderboardBonus;
                    tokenExists = true;
                    break;
                }
            }

            // If token doesn't exist, add it as new reward
            if (!tokenExists) {
                epoch.rewardTokens.push(_rewardTokens[i]);
                epoch.rewardAmounts.push(regularRewardAmount);
                epoch.leaderboardBonusAmounts.push(leaderboardBonus);
            }
        }

        emit RewardsAddedToEpoch(_epochId, _rewardTokens, _rewardAmounts);
    }

    /**
     * @dev Claims rewards for a specific epoch.
     * @param _epochId Epoch ID to claim rewards from.
     */
    function claimEpochRewards(
        uint256 _epochId
    ) external nonReentrant whenNotPaused {
        require(_epochId < epochs.length, "Vault: invalid epoch ID");

        Epoch storage epoch = epochs[_epochId];
        require(epoch.endTime <= block.timestamp, "Vault: epoch not ended");
        UserLock storage userLock = userLocks[msg.sender];
        bool epochFound = false;
        uint256 i = 0;
        uint256 epochsToClaimLength = userLock.epochsToClaim.length;
        for (i; i < epochsToClaimLength; i++) {
            if (userLock.epochsToClaim[i] == _epochId) {
                epochFound = true;
                break;
            }
        }
        require(epochFound, "Vault: epoch not claimable by user");

        uint256 userPower = userEpochVotingPower[msg.sender][_epochId];
        uint256 totalPower = epoch.totalVotingPower;

        require(
            userPower != 0 && totalPower != 0,
            "Vault: no rewards available"
        );
        uint256 rewardLength = epoch.rewardTokens.length;

        // Transfer the user's share of each reward token
        for (uint256 j = 0; j < rewardLength; j++) {
            IERC20 rewardToken = IERC20(epoch.rewardTokens[j]);
            uint256 totalReward = epoch.rewardAmounts[j];
            // user share
            // make sure there are no rounding errors leading to error here
            uint256 userShare = (totalReward * userPower) / totalPower;
            if (userShare > 0) {
                // here make sure also that the math will not leave error of accuracy
                require(
                    rewardToken.balanceOf(address(this)) >= userShare,
                    "Vault: insufficient reward balance"
                );
                rewardToken.transfer(msg.sender, userShare);
            }
        }
        // Remove the epochID from the list of epochs to claim
        userLock.epochsToClaim[i] = userLock.epochsToClaim[
            epochsToClaimLength - 1
        ];
        userLock.epochsToClaim.pop();

        emit RewardsClaimed(msg.sender, _epochId);
    }

    /**
     * @dev Claims the leaderboard bonus for being the vault top holder (cumulative across epochs).
     * @param _epochId Epoch ID to claim leaderboard bonus from.
     */
    function claimLeaderboardBonus(uint256 _epochId) external nonReentrant whenNotPaused {
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        
        Epoch storage epoch = epochs[_epochId];
        require(epoch.endTime <= block.timestamp, "Vault: epoch not ended");
        require(vaultTopHolder == msg.sender, "Vault: not the vault top holder");
        require(!epoch.leaderboardClaimed, "Vault: leaderboard bonus already claimed");
        require(epoch.leaderboardPercentage > 0, "Vault: no leaderboard bonus for this epoch");
        
        epoch.leaderboardClaimed = true;
        
        // Transfer pre-calculated leaderboard bonus amounts
        address[] memory rewardTokens = epoch.rewardTokens;
        uint256[] memory bonusAmounts = epoch.leaderboardBonusAmounts;
        
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (bonusAmounts[i] > 0) {
                require(
                    IERC20(rewardTokens[i]).transfer(msg.sender, bonusAmounts[i]),
                    "Vault: leaderboard bonus transfer failed"
                );
            }
        }
        
        emit LeaderboardBonusClaimed(_epochId, msg.sender, vaultTopHolderCumulativePower, rewardTokens, bonusAmounts);
    }

    /*
     * ==========  READ FUNCTIONS  ==========
     */

    /**
     * @dev Gets the user's current voting power at the current block timestamp.
     *      The voting power decays linearly from lockStart to lockEnd.
     * @param _user The address of the user.
     */
    function getCurrentVotingPower(
        address _user
    ) public view returns (uint256) {
        return getVotingPowerAtTime(_user, block.timestamp);
    }

    /**
     * @dev Gets the user's voting power at a specific future timestamp.
     * @param _user The address of the user.
     * @param _time The future timestamp to check the voting power at.
     */
    function getVotingPowerAtTime(
        address _user,
        uint256 _time
    ) public view returns (uint256) {
        UserLock memory lockData = userLocks[_user];
        if (lockData.amount == 0) {
            return 0;
        }
        if (_time >= lockData.lockEnd) {
            // fully decayed
            return 0;
        }
        uint256 lockDuration = lockData.lockEnd - lockData.lockStart;
        uint256 timeSinceLock = _time - lockData.lockStart;
        if (timeSinceLock > lockDuration) {
            return 0;
        }
        // linear decay
        return
            (lockData.peakVotingPower * (lockDuration - timeSinceLock)) /
            lockDuration;
    }

    /**
     * @dev Returns the user information including locked NFTs.
     * @param _user Address of the user.
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
            NFTLock[] memory lockedNFTs
        )
    {
        UserLock storage lock = userLocks[_user];
        return (
            lock.amount,
            lock.lockStart,
            lock.lockEnd,
            lock.peakVotingPower,
            lock.epochsToClaim,
            lock.lockedNFTs
        );
    }

    /**
     * @dev Returns the locked NFTs for a user.
     * @param _user Address of the user.
     */
    function getUserNFTs(address _user) external view returns (NFTLock[] memory) {
        return userLocks[_user].lockedNFTs;
    }

    /**
     * @dev Returns the count of locked NFTs for a user.
     * @param _user Address of the user.
     */
    function getUserNFTCount(address _user) external view returns (uint256) {
        return userLocks[_user].lockedNFTs.length;
    }

    /**
     * @dev Checks if a specific NFT is locked by a user.
     * @param _user Address of the user.
     * @param _collection Address of the NFT collection.
     * @param _tokenId Token ID of the NFT.
     */
    function isNFTLocked(address _user, address _collection, uint256 _tokenId) external view returns (bool) {
        UserLock storage lock = userLocks[_user];
        uint256 nftCount = lock.lockedNFTs.length;
        
        for (uint256 i = 0; i < nftCount; i++) {
            if (lock.lockedNFTs[i].collection == _collection && lock.lockedNFTs[i].tokenId == _tokenId) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @dev Returns the number of epochs.
     */
    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    /**
     * @dev Returns details of a specific epoch including leaderboard info.
     * @param _epochId Epoch ID.
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
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        Epoch memory epoch = epochs[_epochId];
        return (
            epoch.startTime,
            epoch.endTime,
            epoch.totalVotingPower,
            epoch.rewardTokens,
            epoch.rewardAmounts,
            epoch.leaderboardBonusAmounts,
            epoch.leaderboardPercentage,
            epoch.leaderboardClaimed
        );
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
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        Epoch memory epoch = epochs[_epochId];
        
        rewardTokens = epoch.rewardTokens;
        totalAmounts = new uint256[](rewardTokens.length);
        
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            totalAmounts[i] = epoch.rewardAmounts[i] + epoch.leaderboardBonusAmounts[i];
        }
        
        return (rewardTokens, totalAmounts);
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
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        Epoch memory epoch = epochs[_epochId];
        
        return (epoch.rewardTokens, epoch.leaderboardBonusAmounts);
    }

    /**
     * @dev Gets current vault leaderboard info (cumulative across epochs).
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
        uint256 userPower = userCumulativeVotingPower[_user];
        
        // Calculate user rank (simplified - just check if user is top holder)
        uint256 rank = 0;
        if (userPower > 0) {
            if (_user == vaultTopHolder) {
                rank = 1;
            } else {
                rank = 2; // For simplicity, everyone else is rank 2+
            }
        }
        
        return (
            vaultTopHolder,
            vaultTopHolderCumulativePower,
            rank,
            userPower
        );
    }

    /**
     * @dev Gets a user's cumulative voting power across all epochs.
     * @param _user Address of the user.
     * @return cumulativePower User's total cumulative voting power.
     */
    function getUserCumulativeVotingPower(address _user) external view returns (uint256) {
        return userCumulativeVotingPower[_user];
    }

    /**
     * @dev Checks if a user has contributed to a specific epoch (for cumulative tracking).
     * @param _user Address of the user.
     * @param _epochId Epoch ID to check.
     * @return contributed Whether the user has contributed to this epoch.
     */
    function hasUserContributedToEpoch(address _user, uint256 _epochId) external view returns (bool) {
        return userEpochContributed[_user][_epochId];
    }

    /*
     * ==========  ADMIN FUNCTIONS  ==========
     */

    /**
     * @dev Sets a new vault admin.
     * @param _newAdmin The address of the new admin.
     */
    function setVaultAdmin(address _newAdmin) external onlyVaultAdmin {
        require(_newAdmin != address(0), "Zero address");
        vaultAdmin = _newAdmin;
        emit VaultAdminChanged(vaultAdmin, _newAdmin);
    }

    /**
     * @dev Set the deposit fee rate with a maximum limit of 20%.
     * @param _newFeeRate The new deposit fee rate in basis points (e.g., 2000 = 20%).
     */
    function setDepositFeeRate(uint256 _newFeeRate) external onlyVaultAdmin {
        VaultFactory.TierConfig memory tierConfig = factory.getVaultTierConfig(address(this));
        
        require(tierConfig.canAdjustDepositFee, "Vault: tier doesn't allow fee adjustment");
        require(
            _newFeeRate >= tierConfig.minDepositFeeRate && 
            _newFeeRate <= tierConfig.maxDepositFeeRate, 
            "Vault: fee rate outside tier limits"
        );
        
        uint256 oldRate = depositFeeRate;
        depositFeeRate = _newFeeRate;
        emit DepositFeeRateUpdated(oldRate, _newFeeRate);
    }

    /**
     * @dev Set the fee beneficiary address.
     * @param _newFeeBeneficiary The new fee beneficiary address.
     */
    function setFeeBeneficiaryAddress(
        address _newFeeBeneficiary
    ) external onlyVaultAdmin {
        require(
            _newFeeBeneficiary != address(0),
            "Vault: invalid fee beneficiary address"
        );
        feeBeneficiaryAddress = _newFeeBeneficiary;
        emit FeeBeneficiaryUpdated(feeBeneficiaryAddress, _newFeeBeneficiary);
    }

    /**
     * @dev Enables emergency withdrawal for all users
     */
    function enableEmergencyWithdraw() external onlyVaultAdmin whenPaused {
        require(
            !emergencyWithdrawEnabled,
            "Vault: emergency withdraw already enabled"
        );
        emergencyWithdrawEnabled = true;
        emit EmergencyWithdrawEnabled(msg.sender);
    }

    /**
     * @dev Pauses the vault.
     */
    function pause() external onlyVaultAdmin whenNotPaused {
        paused = true;
        emit VaultStatusChanged(true);
    }

    /**
     * @dev Unpauses the vault.
     */
    function unpause() external onlyVaultAdmin whenPaused {
        require(
            !emergencyWithdrawEnabled,
            "Vault: cannot unpause after emergency withdraw enabled"
        );
        paused = false;
        emit VaultStatusChanged(false);
    }

    /**
     * @dev Emergency token withdrawal by the admin.
     * @param _token Address of the token to withdraw.
     * @param _amount Amount of tokens to withdraw.
     */
    function emergencyWithdraw(
        address _token,
        uint256 _amount
    ) external onlyVaultAdmin whenPaused {
        require(
            emergencyWithdrawEnabled,
            "Vault: emergency withdraw not enabled"
        );
        require(_token != address(token), "Vault: cannot withdraw vault token");
        require(_amount > 0, "Vault: amount must be greater than 0");
        require(
            IERC20(_token).balanceOf(address(this)) >= _amount,
            "Vault: insufficient balance"
        );
        require(
            IERC20(_token).transfer(vaultAdmin, _amount),
            "Vault: transfer failed"
        );
        emit EmergencyTokenWithdraw(_token, _amount);
    }

    /**
     * @dev Emergency withdrawal of locked principal by users
     */
    function emergencyPrincipalWithdraw() external nonReentrant whenPaused {
        require(
            emergencyWithdrawEnabled,
            "Vault: emergency withdraw not enabled"
        );
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: no active lock");

        require(
            token.transfer(msg.sender, lock.amount),
            "Vault: transfer failed"
        );
        emit EmergencyPrincipalWithdraw(msg.sender, lock.amount);
    }

    /**
     * @dev Emergency withdrawal of locked NFTs by users
     */
    function emergencyNFTWithdraw() external nonReentrant whenPaused {
        require(emergencyWithdrawEnabled, "Vault: emergency withdraw not enabled");
        UserLock storage lock = userLocks[msg.sender];
        require(lock.lockedNFTs.length > 0, "Vault: no locked NFTs");

        // Transfer all locked NFTs back to user
        uint256 nftCount = lock.lockedNFTs.length;
        for (uint256 i = 0; i < nftCount; i++) {
            NFTLock memory nftLock = lock.lockedNFTs[i];
            IERC721(nftLock.collection).safeTransferFrom(address(this), msg.sender, nftLock.tokenId);
            emit EmergencyNFTWithdraw(msg.sender, nftLock.collection, nftLock.tokenId);
        }
        
        // Clear the NFT array
        delete lock.lockedNFTs;
    }

    /**
     * @dev Sets NFT collection requirements and boost for voting power.
     * @param _collection Address of the NFT collection.
     * @param _isActive Whether this collection is accepted (ACTIVATE/DEACTIVATE).
     * @param _requiredCount The number of NFTs required.
     * @param _boostPercentage The boost percentage in basis points.
     */
    function setNFTCollectionRequirement(
        address _collection,
        bool _isActive,
        uint256 _requiredCount,
        uint256 _boostPercentage
    ) external onlyVaultAdmin {
        require(_collection != address(0), "Vault: invalid collection address");
        require(_boostPercentage <= 10000, "Vault: boost percentage too high"); // Max 100%
        
        nftCollectionRequirements[_collection] = NFTCollectionRequirement({
            isActive: _isActive,
            requiredCount: _requiredCount,
            boostPercentage: _boostPercentage
        });
        
        emit NFTCollectionRequirementSet(_collection, _isActive, _requiredCount, _boostPercentage);
    }

    /**
     * @dev Calculates the total NFT boost percentage for a user.
     * @param _user Address of the user.
     * @return totalBoost Total boost percentage in basis points.
     */
    function getUserNFTBoost(address _user) public view returns (uint256 totalBoost) {
        UserLock storage lock = userLocks[_user];
        uint256 nftCount = lock.lockedNFTs.length;
        
        if (nftCount == 0) {
            return 0;
        }
        
        // Use mapping to count collections more efficiently
        mapping(address => uint256) storage tempCollectionCounts;
        address[] memory uniqueCollections = new address[](nftCount);
        uint256 uniqueCount = 0;
        
        // Single pass through NFTs to count by collection
        for (uint256 i = 0; i < nftCount; i++) {
            address collection = lock.lockedNFTs[i].collection;
            
            if (tempCollectionCounts[collection] == 0) {
                uniqueCollections[uniqueCount] = collection;
                uniqueCount++;
            }
            tempCollectionCounts[collection]++;
        }
        
        // Calculate boosts
        for (uint256 i = 0; i < uniqueCount; i++) {
            address collection = uniqueCollections[i];
            NFTCollectionRequirement memory requirement = nftCollectionRequirements[collection];
            
            if (requirement.isActive && tempCollectionCounts[collection] >= requirement.requiredCount) {
                totalBoost += requirement.boostPercentage;
            }
        }
        
        return totalBoost;
    }

    /**
     * @dev Gets the count of NFTs for a specific collection that a user has locked.
     * @param _user Address of the user.
     * @param _collection Address of the NFT collection.
     * @return count Number of NFTs from the collection.
     */
    function getUserNFTCountForCollection(address _user, address _collection) public view returns (uint256 count) {
        UserLock storage lock = userLocks[_user];
        uint256 nftCount = lock.lockedNFTs.length;
        
        for (uint256 i = 0; i < nftCount; i++) {
            if (lock.lockedNFTs[i].collection == _collection) {
                count++;
            }
        }
        
        return count;
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
        NFTCollectionRequirement memory requirement = nftCollectionRequirements[_collection];
        
        if (!requirement.isActive) {
            return (false, 0);
        }
        
        uint256 userNFTCount = getUserNFTCountForCollection(_user, _collection);
        qualifies = userNFTCount >= requirement.requiredCount;
        boostPercentage = qualifies ? requirement.boostPercentage : 0;
        
        return (qualifies, boostPercentage);
    }

    /**
     * @dev Deposits multiple NFTs from the same collection.
     * @param _collection Address of the NFT collection.
     * @param _tokenIds Array of token IDs to deposit.
     */
    function depositMultipleNFTs(address _collection, uint256[] calldata _tokenIds) external nonReentrant whenNotPaused {
        require(_collection != address(0), "Vault: invalid collection address");
        require(_tokenIds.length > 0, "Vault: no token IDs provided");
        
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0, "Vault: must have active token lock first");
        require(block.timestamp < lock.lockEnd, "Vault: token lock has expired");
        require(lock.lockedNFTs.length + _tokenIds.length <= MAX_NFTS_PER_USER, "Vault: too many NFTs");
        
        // Check collection is allowed
        NFTCollectionRequirement memory requirement = nftCollectionRequirements[_collection];
        if (requirement.requiredCount > 0 || requirement.boostPercentage > 0) {
            require(requirement.isActive, "Vault: collection not allowed");
        }
        
        IERC721 nftContract = IERC721(_collection);
        
        // Process all NFTs
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            
            // Verify ownership and approval
            require(nftContract.ownerOf(tokenId) == msg.sender, "Vault: not NFT owner");
            require(
                nftContract.getApproved(tokenId) == address(this) || 
                nftContract.isApprovedForAll(msg.sender, address(this)),
                "Vault: NFT not approved"
            );
            
            // Check if NFT is already locked
            require(!isNFTLocked(msg.sender, _collection, tokenId), "Vault: NFT already locked");
            
            // Transfer NFT to vault
            nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
            
            // Add NFT to user's lock
            lock.lockedNFTs.push(NFTLock({
                collection: _collection,
                tokenId: tokenId
            }));
            
            emit NFTDeposited(msg.sender, _collection, tokenId);
        }
        
        // Update user's epoch power once at the end
        _updateUserEpochPower(msg.sender);
    }

    /**
     * @dev Removes/disables NFT collection requirement.
     * @param _collection Address of the NFT collection.
     */
    function removeNFTCollectionRequirement(address _collection) external onlyVaultAdmin {
        require(_collection != address(0), "Vault: invalid collection address");
        delete nftCollectionRequirements[_collection];
        emit NFTCollectionRequirementSet(_collection, false, 0, 0);
    }

    /**
     * @dev Updates the vault tier (only callable by factory during upgrades).
     * @param _newTier The new tier for this vault.
     */
    function updateVaultTier(IVaultFactory.VaultTier _newTier) external {
        require(msg.sender == address(factory), "Vault: only factory can update tier");
        
        IVaultFactory.VaultTier oldTier = vaultTier;
        vaultTier = _newTier;
        
        emit VaultTierUpdated(oldTier, _newTier);
    }

    /**
     * @dev Gets the current tier of this vault.
     */
    function getVaultTier() external view returns (IVaultFactory.VaultTier) {
        return vaultTier;
    }

    /// @notice Event emitted when vault tier is updated
    event VaultTierUpdated(IVaultFactory.VaultTier indexed oldTier, IVaultFactory.VaultTier indexed newTier);
}