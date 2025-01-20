// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface VaultFactory {
    function mainFeeBeneficiary() external view returns (address);
}

/**
 * @title Vault
 * @dev A contract that locks user tokens for a specified duration and provides linear decaying voting power.
 *      Users can participate in epochs to earn rewards distributed proportionally to their voting power.
 */
contract Vault is ReentrancyGuard {
    IERC20 public immutable token;
    VaultFactory public immutable factory;

    /// @notice Define an admin for this vault:
    address public vaultAdmin;
    
    /// @notice Fee beneficiary address
    address public feeBeneficiaryAddress;

    /// @notice The deposit fee rate in basis points (e.g. 100 = 1%)
    uint256 public depositFeeRate;

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

    struct UserLock {
        uint256 amount; // Total tokens locked.
        uint256 lockStart; // Timestamp when lock started.
        uint256 lockEnd; // Timestamp when lock ends.
        uint256 peakVotingPower; // Max voting power at deposit/extension.
        uint256[] epochsToClaim; // Epochs the user can claim rewards from.
    }

    struct Epoch {
        uint256 startTime; // Epoch start time.
        uint256 endTime; // Epoch end time.
        uint256 totalVotingPower; // Total voting power in this epoch.
        address[] rewardTokens; // List of reward tokens.
        uint256[] rewardAmounts; // Corresponding reward amounts.
    }

    /// @notice Mapping to store user locks based on their address
    mapping(address => UserLock) public userLocks;
    
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
    event ExtendedLock(address indexed user, uint256 newAmount, uint256 newLockEnd);

    /// @notice Event emitted when tokens are withdrawn from the vault.
    /// @param user The address of the user who withdrew the tokens.
    /// @param amount The amount of tokens withdrawn.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Event emitted when a new epoch is started.
    /// @param epochId The ID of the new epoch.
    /// @param rewardTokens The list of reward tokens for the epoch.
    /// @param rewardAmounts The corresponding reward amounts for the epoch.
    /// @param endTime The end time of the epoch.
    event EpochStarted(uint256 indexed epochId, address[] rewardTokens, uint256[] rewardAmounts, uint256 endTime);

    /// @notice Event emitted when rewards are claimed by a user.
    /// @param user The address of the user who claimed the rewards.
    /// @param epochId The ID of the epoch from which rewards were claimed.
    event RewardsClaimed(address indexed user, uint256 indexed epochId);

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
     */
    constructor(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory,
        address _feeBeneficiary
    ) {
        require(_token != address(0), "Vault: invalid token");
        require(_vaultAdmin != address(0), "Vault: invalid admin");
        require(_factory != address(0), "Vault: invalid factory");
        require(_feeBeneficiary != address(0), "Vault: invalid beneficiary");

        token = IERC20(_token);
        depositFeeRate = _depositFeeRate;
        vaultAdmin = _vaultAdmin;
        factory = VaultFactory(_factory);
        feeBeneficiaryAddress = _feeBeneficiary;
    }

    /*
     * ==========  MAIN FUNCTIONS  ==========
     */

    /**
     * @dev Deposits tokens into the vault and locks them for the specified duration.
     * @param _amount Amount of tokens to deposit.
     * @param _duration Lock duration in seconds.
     */
    function deposit(uint256 _amount, uint256 _duration) external nonReentrant whenNotPaused {
        require(_amount >= MIN_LOCK_AMOUNT, "Vault: amount too small");
        require(_duration >= MIN_LOCK_DURATION && _duration <= MAX_LOCK_DURATION, "Vault: invalid duration");

        uint256 fee = (_amount * depositFeeRate) / 10000;
        uint256 netAmount = _amount - fee;

        require(token.transferFrom(msg.sender, address(this), _amount), "Vault: transfer failed");
        if (fee > 0) {
            require(token.transfer(feeBeneficiaryAddress, fee / 2), "Vault: fee transfer failed");
            require(token.transfer(factory.mainFeeBeneficiary(), fee / 2), "Vault: fee transfer failed");
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
    function expandLock(uint256 _additionalAmount, uint256 _duration) external nonReentrant whenNotPaused {
        require(_additionalAmount > 0 || _duration > 0, "Vault: either one should be positive")

        if (_additionalAmount > 0) {
            uint256 fee = _additionalAmount * depositFeeRate / 10000;
            uint256 netAmount = _additionalAmount - fee;

            require(token.transferFrom(msg.sender, address(this), netAmount), "Vault: transfer failed");
            if (fee > 0) {
                require(token.transfer(feeBeneficiaryAddress, fee/2), "Vault: fee transfer failed");
                require(token.transfer(factory.mainFeeBeneficiary(), fee/2), "Vault: fee transfer failed");
            }

            _expandLock(msg.sender, _additionalAmount, _duration == 0 ? 0 : block.timestamp + _duration);
        } else {
            // purely extend lock time
            _expandLock(msg.sender, 0, block.timestamp + _duration);
        }

        // Update user’s epoch contribution if there’s an active epoch
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

        lock.amount = 0;
        lock.lockEnd = 0;
        lock.lockStart = 0;
        lock.peakVotingPower = 0;

        require(token.transfer(msg.sender, withdrawable), "Vault: transfer failed");
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
        require(userEpochVotingPower[msg.sender][currentEpochId] == 0, "Vault: already registered for this epoch");

        _updateUserEpochPower(msg.sender);

        emit Participated(msg.sender, currentEpochId, medianVotingPower);
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
            require(lockData.lockEnd > block.timestamp, "Vault: current lock expired extend it first");
        }
        // Refresh current voting power
        // Then we recalc the new peakVotingPower as old leftover + new deposit
        uint256 currentVotingPower = getCurrentVotingPower(_user);

        // The new peakVotingPower can be considered as the current voting power 
        // "carried forward" plus the new deposit.  For simplicity, let's just set:
        lockData.peakVotingPower = currentVotingPower + _extraAmount;

        // If user wants to set a new end time that is > oldLockEnd we set new lockEnd
        // If not, we keep the old lockEnd
        if (_newEnd > oldLockEnd) {
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
     * @dev Updates user’s epoch voting power for the current active epoch.
     *      Called whenever user deposits, extends, withdraws. 
     *      Adjusts the vault’s total voting power in that epoch as well.
     */
    function _updateUserEpochPower(address _user) internal {
        // If no active epoch, skip
        if (epochs.length == 0) return;
        UserLock storage lockData = userLocks[_user];
        Epoch storage epoch = epochs[currentEpochId];
        if (epoch.endTime <= block.timestamp) return;

        // 1. Subtract old power from epoch total
        uint256 oldUserPower = userEpochVotingPower[_user][currentEpochId];

        if (oldUserPower > 0) {
            epoch.totalVotingPower = epoch.totalVotingPower > oldUserPower 
                ? epoch.totalVotingPower - oldUserPower 
                : 0;
        } else {
            lockData.epochsToClaim.push(currentEpochId);
        }

        UserLock storage lockData = userLocks[_user];
        if (lockData.amount == 0) return;

        uint256 effectiveStart = lockData.lockStart > epoch.startTime ? lockData.lockStart : epoch.startTime;
        uint256 effectiveEnd = lockData.lockEnd < epoch.endTime ? lockData.lockEnd : epoch.endTime;

        if (effectiveStart >= effectiveEnd) {
            userEpochVotingPower[_user][currentEpochId] = 0;
            return;
        }

        uint256 vpStart = getVotingPowerAtTime(_user, effectiveStart);
        uint256 vpEnd = getVotingPowerAtTime(_user, effectiveEnd);

        uint256 areaUnderCurve = (vpStart + vpEnd) * (effectiveEnd - effectiveStart) / 2;
        userEpochVotingPower[_user][currentEpochId] = areaUnderCurve;
        epoch.totalVotingPower += areaUnderCurve;
    }

    /**
     * @dev Updates user’s epoch voting power for the current active epoch.
     *      Called whenever user deposits, extends, or withdraws. 
     *      Adjusts the vault’s total voting power in that epoch as well.
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
            uint256 effectiveEnd = lockData.lockEnd < epoch.endTime ? lockData.lockEnd : epoch.endTime;

            if (effectiveStart >= effectiveEnd) {
                return;
            }

            uint256 vpStart = getVotingPowerAtTime(_user, effectiveStart);
            uint256 vpEnd = getVotingPowerAtTime(_user, effectiveEnd);

            uint256 areaUnderCurve = (vpStart + vpEnd) * (effectiveEnd - effectiveStart) / 2;
            if (areaUnderCurve > oldUserPower) 
            userEpochVotingPower[_user][currentEpochId] = 0;
            userEpochVotingPower[_user][currentEpochId] = oldUserPower - areaUnderCurve;
            if (areaUnderCurve > epoch.totalVotingPower)
            epoch.totalVotingPower = 0;
            epoch.totalVotingPower -= areaUnderCurve;
            if (userEpochVotingPower[_user][currentEpochId] == 0) {
                uint256 epochsToClaimLength = lockData.epochsToClaim.length;
                for (uint256 i = 0; i < epochsToClaimLength; i++) {
                    if (epochsToClaim[i] == currentEpochId) {
                        epochsToClaim[i] = lockData.epochsToClaim[epochsToClaimLength - 1];
                        epochsToClaim.pop();
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
     * @dev Starts a new epoch for reward distribution.
     * @param _rewardTokens List of reward token addresses.
     * @param _rewardAmounts List of reward token amounts.
     * @param _endTime Epoch end time.
     */
    function startEpoch(
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts,
        uint256 _endTime
    ) external onlyVaultAdmin whenNotPaused {
        require(_rewardTokens.length == _rewardAmounts.length, "Vault: mismatched arrays");
        require(_endTime > block.timestamp, "Vault: invalid end time");
        require(
            _endTime - block.timestamp >= MIN_EPOCH_DURATION && _endTime - block.timestamp <= MAX_EPOCH_DURATION,
            "Vault: invalid epoch duration"
        );

        uint256 rewardTokensLength = _rewardTokens.length;
        for (uint256 i = 0; i < rewardTokensLength; i++) {
            require(IERC20(_rewardTokens[i]).allowance(msg.sender, address(this)) >= _rewardAmounts[i], "Vault: insufficient allowance");
            require(IERC20(_rewardTokens[i]).balanceOf(msg.sender) >= _rewardAmounts[i], "Vault: insufficient rewards");
            require(IERC20(_rewardTokens[i]).transferFrom(msg.sender, address(this), _rewardAmounts[i]), "Vault: transfer failed");
        }

        if (epochs.length > 0) {
            Epoch storage prevEpoch = epochs[currentEpochId];
            require(prevEpoch.endTime <= block.timestamp, "Vault: previous epoch not ended");
        }

        epochs.push(
            Epoch({
                startTime: block.timestamp,
                endTime: _endTime,
                rewardTokens: _rewardTokens,
                rewardAmounts: _rewardAmounts,
                totalVotingPower: 0
            })
        );

        currentEpochId = epochs.length - 1;
        emit EpochStarted(currentEpochId, _rewardTokens, _rewardAmounts, _endTime);
    }

    /**
     * @dev Claims rewards for a specific epoch.
     * @param _epochId Epoch ID to claim rewards from.
     */
    function claimEpochRewards(uint256 _epochId) external nonReentrant whenNotPaused {
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
        
        require(userPower != 0 && totalPower != 0, "Vault: no rewards available");
        uint256 rewardLength = epoch.rewardTokens.length;

        // Transfer the user’s share of each reward token
        for (uint256 i = 0; i < rewardLength; i++) {
            IERC20 rewardToken = IERC20(epoch.rewardTokens[i]);
            uint256 totalReward = epoch.rewardAmounts[i];
            // user share
            // make sure there are no rounding errors leading to error here
            uint256 userShare = (totalReward * userPower) / totalPower;
            if (userShare > 0) {
                // here make sure also that the math will not leave error of accuracy
                require(rewardToken.balanceOf(address(this)) >= userShare, "Vault: insufficient reward balance");
                rewardToken.transfer(msg.sender, userShare);
            }
        }
        // Remove the epochID from the list of epochs to claim
        userLock.epochsToClaim[i] = userLock.epochsToClaim[epochsToClaimLength - 1];
        userLock.epochsToClaim.pop();

        emit RewardsClaimed(msg.sender, _epochId);
    }

    /* 
     * ==========  READ FUNCTIONS  ==========
     */

    /**
     * @dev Gets the user's current voting power at the current block timestamp.
     *      The voting power decays linearly from lockStart to lockEnd.
     * @param _user The address of the user.
     */
    function getCurrentVotingPower(address _user) public view returns(uint256) {
        return getVotingPowerAtTime(_user, block.timestamp);
    }

    /**
     * @dev Gets the user’s voting power at a specific future timestamp.
     * @param _user The address of the user.
     * @param _time The future timestamp to check the voting power at.
     */
    function getVotingPowerAtTime(address _user, uint256 _time) public view returns(uint256) {
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
        return lockData.peakVotingPower * (lockDuration - timeSinceLock) / lockDuration;
    }

    /**
     * @dev Returns the number of epochs.
     * @param _user Address of the user.
     */
    function getUserInfo(address _user)
        external
        view
        returns (
            uint256 amount,
            uint256 lockStart,
            uint256 lockEnd,
            uint256 peakVotingPower,
            uint256[] memory epochsToClaim
        )
    {
        UserLock storage lock = userLocks[_user];
        return (lock.amount, lock.lockStart, lock.lockEnd, lock.peakVotingPower, lock.epochsToClaim);
    }

    /**
     * @dev Returns the number of epochs.
     */
    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    /**
     * @dev Returns details of a specific epoch.
     * @param _epochId Epoch ID.
     */
    function getEpochInfo(uint256 _epochId)
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 totalVotingPower,
            address[] memory rewardTokens,
            uint256[] memory rewardAmounts
        )
    {
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        Epoch memory epoch = epochs[_epochId];
        return (epoch.startTime, epoch.endTime, epoch.totalVotingPower, epoch.rewardTokens, epoch.rewardAmounts);
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
    }

    /**
     * @dev Set the deposit fee rate with a maximum limit of 20%.
     * @param _newFeeRate The new deposit fee rate in basis points (e.g., 2000 = 20%).
     */
    function setDepositFeeRate(uint256 _newFeeRate) external onlyVaultAdmin {
        require(_newFeeRate <= 2000, "Vault: fee rate too high");
        depositFeeRate = _newFeeRate;
    }

    /**
     * @dev Set the fee beneficiary address.
     * @param _newFeeBeneficiary The new fee beneficiary address.
     */
    function setFeeBeneficiaryAddress(address _newFeeBeneficiary) external onlyVaultAdmin {
        require(_newFeeBeneficiary != address(0), "Vault: invalid fee beneficiary address");
        feeBeneficiaryAddress = _newFeeBeneficiary;
    }

    /**
     * @dev Pauses the vault.
     */
    function pause() external onlyVaultAdmin {
        paused = true;
    }

    /**
     * @dev Unpauses the vault.
     */
    function unpause() external onlyVaultAdmin {
        paused = false;
    }

    /**
     * @dev Emergency token withdrawal by the admin.
     * @param _token Address of the token to withdraw.
     * @param _amount Amount of tokens to withdraw.
     */
    function emergencyWithdraw(address _token, uint256 _amount) external onlyVaultAdmin whenPaused {
        require(_amount > 0, "Vault: amount must be greater than 0");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Vault: insufficient balance");

        require(IERC20(_token).transfer(vaultAdmin, _amount), "Vault: transfer failed");
    }
}
