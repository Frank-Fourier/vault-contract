// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


/* 
 * Interfaces
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/* 
 * Vault
 * -----
 * 1. Locks user tokens for 12 months (for example).
 * 2. Voting power decays linearly from deposit time to lock end.
 * 3. Users can deposit or extend the lock time/amount. 
 * 4. Epoch-based reward distribution:
 *    - Admin starts new epoch, sets reward tokens and amounts
 *    - At epoch end, rewards are claimable, distributed by share of voting power
 * 5. A deposit fee is taken and sent to the factory (or stored).
 * 6. If a user’s lock ends mid-epoch or they withdraw early, partial voting power counts.
 */

interface VaultFactory {
    function factoryFeeCollector() external view returns (address);
}

contract Vault is ReentrancyGuard {
    IERC20 public immutable token;
    VaultFactory public immutable factory;

    // The deposit fee rate in basis points (e.g. 100 = 1%)
    uint256 public depositFeeRate; 

    // Each Vault can have its own admin or could rely on the factory admin; 
    // for simplicity, define an admin for this vault:
    address public vaultAdmin;
    
    // Fee beneficiary address
    address public feeBeneficiaryAddress;

    // Max Epoch Duration
    uint256 public constant MAX_EPOCH_DURATION = 8 weeks;

    // Minimum duration for an epoch
    uint256 public constant MIN_EPOCH_DURATION = 1 weeks;

    // Minimum amount of tokens required to lock
    uint256 public constant MIN_LOCK_AMOUNT = 1_000 * 10 ** 18;

    // Maximum duration for which tokens can be locked (52 weeks)
    uint256 public constant MAX_LOCK_DURATION = 52 weeks;

    // Minimum duration for which tokens can be locked (1 week)
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;

    /* 
     * Lock data 
     */
    struct UserLock {
        uint256 amount;        // total tokens locked
        uint256 lockStart;     // timestamp when lock started
        uint256 lockEnd;       // timestamp when lock ends
        // "peakVotingPower" can be conceptually the user's 
        // max voting power at the time of deposit/extension.
        uint256 peakVotingPower;
        uint256[] epochsToClaim;
    }

    // user => UserLock 
    mapping(address => UserLock) public userLocks;

    // has claimed mapping
    mapping(address => mapping(uint256 => bool)) public hasClaimed;

    /*
     * Epoch data
     */
    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        // total final voting power locked in this epoch (snapshot at end)
        uint256 totalVotingPower;
        // reward tokens + amounts
        address[] rewardTokens;
        uint256[] rewardAmounts;
    }
    Epoch[] public epochs;
    uint256 public currentEpochId;

    // For reward distribution, we track user’s share in each epoch
    // user => epochId => storedVotingPower
    // This is the user’s voting power snapshot for that epoch. Adjusted as deposit or withdraw happen.
    mapping(address => mapping(uint256 => uint256)) public userEpochVotingPower;

    // Events
    event Deposited(address indexed user, uint256 amount, uint256 fee);
    event ExtendedLock(address indexed user, uint256 newAmount, uint256 newLockEnd);
    event Withdrawn(address indexed user, uint256 amount);
    event EpochStarted(uint256 indexed epochId, address[] rewardTokens, uint256[] rewardAmounts, uint256 endTime);
    event EpochEnded(uint256 indexed epochId, uint256 totalVotingPower);
    event RewardsClaimed(address indexed user, uint256 indexed epochId);

    modifier onlyVaultAdmin() {
        require(msg.sender == vaultAdmin, "Vault: Not vault admin");
        _;
    }

    constructor(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory
    ) {
        require(_token != address(0), "Vault: invalid token");
        require(_vaultAdmin != address(0), "Vault: invalid admin");
        require(_factory != address(0), "Vault: invalid factory");

        token = IERC20(_token);
        depositFeeRate = _depositFeeRate;
        vaultAdmin = _vaultAdmin;
        factory = VaultFactory(_factory);

        // Start with epochId = 0 (no active epochs yet)
        currentEpochId = 0;
    }

    /* 
     * ==========  Core Lock Logic  ==========
     */

    /**
     * @dev Deposit tokens and lock them for the default LOCK_DURATION (12 months).
     */
    function deposit(uint256 _amount, uint256 _duration) external nonReentrant {
        require(_amount >= MIN_LOCK_AMOUNT, "Vault: amount too small");
        require(_duration >= MIN_LOCK_DURATION && _duration <= MAX_LOCK_DURATION, "Vault: invalid duration");

        // Take fee
        uint256 fee = _amount * depositFeeRate / 10000;
        uint256 netAmount = _amount - fee;

        // Transfer tokens from user to vault
        require(token.transferFrom(msg.sender, address(this), _amount), "Vault: transfer failed");

        // Send fee portion to the factory's feeCollector
        if (fee > 0) {
            require(token.transfer(factory.factoryFeeCollector(), fee), "Vault: fee transfer failed");
        }

        UserLock storage userLock = userLocks[msg.sender];

        if (userLock.amount == 0 ) {
            // First-time deposit
            userLock.amount = netAmount;
            userLock.lockStart = block.timestamp;
            userLock.lockEnd = block.timestamp + _duration;
            userLock.peakVotingPower = netAmount; 
        } else {
            revert("Vault: cannot deposit while lock is active");
        }

        // Update user’s epoch contribution if there’s an active epoch
        _updateUserEpochPower(msg.sender);

        emit Deposited(msg.sender, _amount, fee);
    }

    /**
     * @dev Extend lock time or add more tokens.
     *      newLockEnd > current lockEnd if we want a time extension,
     *      or addAmount > 0 to lock more tokens.
     */
    function expandLock(uint256 _additionalAmount, uint256 _duration) external nonReentrant {
        require(_additionalAmount > 0 || _duration > 0, "Vault: either one should be positive")

        if (_additionalAmount > 0) {
            uint256 fee = _additionalAmount * depositFeeRate / 10000;
            uint256 netAmount = _additionalAmount - fee;

            require(token.transferFrom(msg.sender, address(this), netAmount), "Vault: transfer failed");
            if (fee > 0) {
                require(token.transfer(factory.factoryFeeCollector(), fee), "Vault: fee transfer failed");
            }

            _expandLock(msg.sender, _additionalAmount, _duration == 0 ? 0 : block.timestamp + _duration);
        } else {
            // purely extend lock time
            _expandLock(msg.sender, 0, block.timestamp + _duration);
        }

        // Update user’s epoch contribution if there’s an active epoch
        _updateUserEpochPower(msg.sender);
    }

    function _expandLock(
        address _user, 
        uint256 _extraAmount, 
        uint256 _newEnd // set to 0 if not used
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
     * @dev Withdraw tokens if lock period is over (lockEnd <= block.timestamp).
     *      If still inside an active epoch, that epoch’s voting power is adjusted.
     */
    function withdraw() external nonReentrant {
        UserLock storage lockData = userLocks[msg.sender];
        require(lockData.amount > 0, "Vault: nothing to withdraw");
        require(block.timestamp >= lockData.lockEnd, "Vault: lock not ended");

        uint256 withdrawable = lockData.amount;

        // reduce user epoch voting power if needed
        // Actually, since the user is fully unlocking after the lock ended, 
        // we basically "zero" them out for subsequent calculations, 
        // but keep partial for the current epoch if it's still active.

        // If there's an active epoch, we recalc them at the time of withdrawal
        _reduceUserEpochPower(msg.sender);

        // Clear user lock
        lockData.amount = 0;
        lockData.lockEnd = 0;
        lockData.lockStart = 0;
        lockData.peakVotingPower = 0;

        // Transfer tokens back to user
        require(token.transfer(msg.sender, withdrawable), "Vault: transfer failed");
        emit Withdrawn(msg.sender, withdrawable);
    }

    /*
     * ==========  Voting Power Logic  ==========
     * 
     * For simplicity, we treat voting power as linear decay from 
     * lockStart => lockEnd (12 months).
     * 
     * At time T in [lockStart, lockEnd],
     *   userVP(T) = peakVotingPower * (1 - (T - lockStart)/(lockEnd - lockStart))
     * or 0 if T > lockEnd
     */

    /**
     * @dev Get the user’s current voting power at block.timestamp 
     *      based on linear decay from lockStart => lockEnd.
     */
    function getCurrentVotingPower(address _user) public view returns(uint256) {
        return getVotingPowerAtTime(_user, block.timestamp);
    }

    /**
     * @dev Get the user’s voting power at a specific future timestamp
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
     *      Called whenever user deposits, extends, withdraws. 
     *      Adjusts the vault’s total voting power in that epoch as well.
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
     * ==========  Epoch Logic  ==========
     * 
     * Each epoch is started by the vault admin, specifying reward tokens and amounts.
     * Users' voting power is aggregated. When epoch ends, distribution is done.
     */

    /**
     * @dev Admin manually starts a new epoch.
     *      Must end the current epoch first if it is still active.
     */
    function startEpoch(address[] calldata _rewardTokens, uint256[] calldata _rewardAmounts, uint256 _endTime) external onlyVaultAdmin {
        const _startTime = block.timestamp;
        require(_rewardTokens.length == _rewardAmounts.length, "Vault: mismatched arrays");
        require(_endTime > block.timestamp, "Vault: invalid end time");
        require(_endTime - block.timestamp <= MAX_EPOCH_DURATION, "Vault: Epoch too long");
        require(_endTime - _startTime >= MIN_EPOCH_DURATION, "Vault: Epoch too short");

        // should instead handle transfers from the vaultAdmin to the contract
        uint256 rewardTokensLength = _rewardTokens.length;
        for (uint256 i = 0; i < rewardTokensLength; i++) {
            require(IERC20(_rewardTokens[i]).balanceOf(address(this)) >= _rewardAmounts[i], "Vault: insufficient rewards");
            require(IERC20(_rewardTokens[i]).transferFrom(msg.sender, address(this), _rewardAmounts[i]), "Vault: transfer failed");
        }

        // End the previous epoch first
        if (epochs.length > 0) {
            Epoch storage prevEpoch = epochs[currentEpochId];
            require(prevEpoch.endTime <= block.timestamp, "Vault: previous epoch not ended");
        }

        uint256 newEpochId = epochs.length; 
        Epoch memory e;
        e.startTime = block.timestamp;
        e.endTime = _endTime;
        e.rewardTokens = _rewardTokens;
        e.rewardAmounts = _rewardAmounts;
        e.totalVotingPower = 0;
        epochs.push(e);

        currentEpochId = newEpochId;
        emit EpochStarted(newEpochId, _rewardTokens, _rewardAmounts, _endTime);
    }

    /**
     * @dev User claims rewards from a given epoch once it is ended.
     *      The share is (userEpochVotingPower / totalVotingPower) for that epoch.
     */
    function claimEpochRewards(uint256 _epochId) external nonReentrant {
        require(_epochId < epochs.length, "Vault: invalid epoch ID");
        Epoch storage epoch = epochs[_epochId];
        require(epoch.endTime <= block.timestamp, "Vault: epoch not ended");
        require(!hasClaimed[msg.sender][_epochId], "Vault: already claimed");
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

        hasClaimed[msg.sender][_epochId] = true;
        // Remove the epochID from the list of epochs to claim
        userLock.epochsToClaim[i] = userLock.epochsToClaim[epochsToClaimLength - 1];
        userLock.epochsToClaim.pop();

        emit RewardsClaimed(msg.sender, _epochId);
    }

    /* 
     * ==========  Helper Views  ==========
     */
    function getEpochCount() external view returns(uint256) {
        return epochs.length;
    }

    function getEpochInfo(uint256 _epochId) 
        external 
        view 
        returns(
            uint256 startTime,
            uint256 endTime,
            uint256 totalVP,
            address[] memory rewardToks,
            uint256[] memory rewardAmts,
        ) 
    {
        require(_epochId < epochs.length, "Invalid epochId");
        Epoch memory e = epochs[_epochId];
        return (
            e.startTime,
            e.endTime,
            e.totalVotingPower,
            e.rewardTokens,
            e.rewardAmounts,
        );
    }

    function setVaultAdmin(address _newAdmin) external onlyVaultAdmin {
        require(_newAdmin != address(0), "Zero address");
        vaultAdmin = _newAdmin;
    }
}
