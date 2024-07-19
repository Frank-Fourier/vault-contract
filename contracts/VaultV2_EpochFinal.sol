// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title  Vault
 * @author Rekt/KurgerBing69/FrankFourier
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./dependencies/Ownable.sol";

contract Vault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Constants core parameters$
    /// @notice Assumption: 1 block every 2 seconds adjusted to Base
    uint public constant BLOCKS_PER_DAY = 43_200;
    /// @notice Lock period of 1 year worth of blocks
    //uint public constant LOCK_PERIOD = BLOCKS_PER_DAY * 365; //uncomment for mainnet
    uint public constant LOCK_PERIOD = 600; //for testing on base
    /// @notice Minimum tokens required for locking
    uint public constant MIN_LOCK_AMOUNT = 1_000 * 10 ** 18;
    /// @notice Max number of users who can lock tokens
    uint public maxActiveUsers = 1_000;
    /// @notice Deposit fee percentage
    uint public constant DEPOSIT_FEE_PERCENT = 1;
    /// @dev Maps and state variables
    /// @notice Fee beneficiary
    address public feeBeneficiary;
    /// @notice Number of reward distributions
    uint public distributionRounds;
    /// @notice Locked tokens
    uint public totalLockedTokens;
    /// @notice Current epoch id
    uint256 public currentEpochId;
    /// @notice Epoch duration
    uint256 public epochDuration;
    /// @notice Active users array
    address[] public activeUsers;
    /// @notice Array to store reward token addresses
    address[] public rewardTokenAddresses;

    /// @notice Stores user token lock details
    struct UserLock {
        uint256 lockedTokens; ///< Amount of tokens locked
        uint256 virtualLockedTokens; ///< Virtual principal amount
        uint256 lockStartBlock; ///< Start time when tokens were locked
        uint256 lockEndBlock; ///< End time when tokens will be unlocked
        uint256 lastClaimedEpoch; ///< Last epoch claimed
    }

    /// @notice Struct to store reward token details
    struct RewardToken {
        address tokenAddress;
        uint availableRewards;
        uint epochsLeft;
    }
    /// @notice Struct to store epoch rewards details
    struct EpochRewards {
        address[] rewardTokens;
        uint256[] rewardAmounts;
        uint256[] rewardsClaimed;
    }
    /// @notice Struct to store epoch details
    struct Epoch {
        uint256 startBlock;
        uint256 endBlock;
        uint256 totalSupplyAtStart;
    }

    /// @notice Mapping of user addresses to their respective lock information
    mapping(address => UserLock) public userLockInfo;
    /// @notice Mapping with authorized users
    mapping(address => bool) public authorized;
    /// @notice Mapping to store reward token details
    mapping(address => RewardToken) public rewardTokens;
    /// @notice Mapping to store epoch details
    mapping(uint256 => Epoch) public epochs;
    /// @notice Mapping to store epoch rewards details
    mapping(uint256 => EpochRewards) internal epochRewardsInfo;

    /// @notice Erc20 token to lock in the Vault
    IERC20 public immutable vaultToken;

    ////////////////// EVENTS //////////////////

    /// @notice Event emitted when tokens are sent from an account to another
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Event emitted when user deposit fund to our vault
    event TokensLocked(address indexed user, uint amount, uint lockEndBlock);

    /// @notice Event emitted when user extends lock period or add amount
    event LockExtended(
        address indexed user,
        uint amountAdded,
        uint newLockEndBlock
    );

    /// @notice Event emitted when user claim their locked tokens
    event TokensUnlocked(address indexed user, uint amount);
    /// @notice Event emitted when user claim their rewards
    event RewardsFunded(address indexed token, uint amount, uint nEpochs);
    /// @notice Event emitted when user claim their rewards
    event RewardsClaimed(address indexed user, uint256 epochId);
    /// @notice Event emitted emergency unlock is triggered
    event EmergencyUnlockTriggered(address indexed user, uint amount);
    /// @notice Event emitted when epoch is finalized
    event EpochFinalized(uint256 epochId);
    /// @notice Event emitted when admin withdraws ERC20 sent by mistake to the contract
    event ERC20Withdrawn(address indexed token, uint amount);

    ////////////////// MODIFIER //////////////////

    modifier onlyAuthorized() {
        require(authorized[msg.sender], "ERR_V.1");
        _;
    }

    ////////////////// CONSTRUCTOR /////////////////////

    constructor(
        address _owner,
        address _vaultToken,
        address _feeBeneficiary,
        uint _epochDuration
    ) {
        require(_owner != address(0), "Invalid owner address");
        require(_vaultToken != address(0), "Invalid ERC20 address");
        require(
            _feeBeneficiary != address(0),
            "Invalid fee beneficiary address"
        );

        transferOwnership(_owner); // Set owner
        vaultToken = IERC20(_vaultToken); // Associate ERC20 token
        authorized[_owner] = true; // Grant authorization to owner
        feeBeneficiary = _feeBeneficiary; // Set fee beneficiary
        rewardTokens[_vaultToken] = RewardToken({
            tokenAddress: _vaultToken,
            epochsLeft: 0,
            availableRewards: 0
        });
        // Add vault token as the first reward token
        rewardTokenAddresses.push(_vaultToken);
        epochDuration = _epochDuration;
    }

    ////////////////// SETTER //////////////////

    /// @notice Sets new beneficiary address
    /// @param _newBeneficiary New beneficiary address
    function setFeeBeneficiary(address _newBeneficiary) external onlyOwner {
        require(
            _newBeneficiary != address(0) && _newBeneficiary != feeBeneficiary,
            "Invalid address"
        );
        feeBeneficiary = _newBeneficiary;
    }

    /// @notice Add authorized user
    /// @param _user Address of the user
    function setAuthorizedUser(address _user, bool _state) external onlyOwner {
        require(_user != address(0), "Invalid address");
        require(authorized[_user] != _state, "Invalid state");
        authorized[_user] = _state;
    }

    /// @notice Function to add a reward token
    /// @param _tokenAddress Address of the reward token
    function setRewardToken(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(0), "Invalid token address");
        require(
            rewardTokens[_tokenAddress].tokenAddress == address(0),
            "Token already added"
        );

        rewardTokens[_tokenAddress] = RewardToken({
            tokenAddress: _tokenAddress,
            availableRewards: 0,
            epochsLeft: 0
        });
        rewardTokenAddresses.push(_tokenAddress);
    }

    function removeRewardToken(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(0), "Invalid token address");
        require(
            rewardTokens[_tokenAddress].tokenAddress != address(0),
            "Token not added"
        );

        delete rewardTokens[_tokenAddress];
        for (uint i = 0; i < rewardTokenAddresses.length; i++) {
            if (rewardTokenAddresses[i] == _tokenAddress) {
                rewardTokenAddresses[i] = rewardTokenAddresses[
                    rewardTokenAddresses.length - 1
                ];
                rewardTokenAddresses.pop();
                break;
            }
        }
    }

    ////////////////// READ //////////////////

    function name() external view virtual returns (string memory) {
        return "GMB Vault Token";
    }

    function decimals() external view virtual returns (uint8) {
        return 18;
    }

    function symbol() external view virtual returns (string memory) {
        return "GMBee";
    }

    /**
     * @notice Get adjusted total Supply
     */
    function totalSupply() public view virtual returns (uint) {
        return _getTotalAdjustedLockedTokens();
    }

    /**
     * @notice Get the current adjusted balance of locked tokens for a user
     * @param user The address of the user
     * @return The adjusted amount of locked tokens
     */
    function balanceOf(address user) public view returns (uint) {
        return _getAdjustedLockedTokens(user, block.number);
    }

    /**
     * @notice Get the adjusted balance of locked tokens for a user at a specific block
     * @param user The address of the user
     * @param blockNumber The block number at which to evaluate the balance
     * @return The adjusted amount of locked tokens at the given block
     */
    function balanceOfAt(
        address user,
        uint blockNumber
    ) public view returns (uint) {
        require(
            blockNumber <= block.number,
            "Query block number is in the future"
        );
        return _getAdjustedLockedTokens(user, blockNumber);
    }

    function getEpochRewards(
        uint256 epochId
    )
        external
        view
        returns (address[] memory, uint256[] memory, uint256[] memory)
    {
        return (
            epochRewardsInfo[epochId].rewardTokens,
            epochRewardsInfo[epochId].rewardAmounts,
            epochRewardsInfo[epochId].rewardsClaimed
        );
    }

    ////////////////// AUXILIARY //////////////////

    /**
     * @notice Internal function to calculate adjusted locked tokens based on a specific block number
     * @param user The address of the user
     * @param blockNumber The block number for which to calculate the balance
     * @return The adjusted locked tokens based on elapsed time
     */
    function _getAdjustedLockedTokens(
        address user,
        uint256 blockNumber
    ) internal view returns (uint256) {
        UserLock memory lock = userLockInfo[user];
        if (
            blockNumber > lock.lockEndBlock ||
            lock.lockedTokens == 0 ||
            blockNumber <= lock.lockStartBlock
        ) {
            return 0;
        } else {
            uint256 elapsed = blockNumber - lock.lockStartBlock;
            uint256 totalDuration = lock.lockEndBlock - lock.lockStartBlock;
            return (lock.virtualLockedTokens * elapsed) / totalDuration;
        }
    }

    /**
     * @notice Calculate and return the total adjusted locked tokens for all users based on elapsed time
     * @return totalAdjustedLockedTokens The total number of adjusted locked tokens across all users
     */
    function _getTotalAdjustedLockedTokens()
        internal
        view
        returns (uint totalAdjustedLockedTokens)
    {
        uint currentBlock = block.number;
        totalAdjustedLockedTokens = 0;

        for (uint i = 0; i < activeUsers.length; i++) {
            totalAdjustedLockedTokens += _getAdjustedLockedTokens(
                activeUsers[i],
                currentBlock
            );
        }

        return totalAdjustedLockedTokens;
    }

    /**
     * @notice Internal function to remove an active user
     * @param user The address of the user to remove
     */
    function _removeActiveUser(address user) internal {
        for (uint i = 0; i < activeUsers.length; i++) {
            if (activeUsers[i] == user) {
                activeUsers[i] = activeUsers[activeUsers.length - 1];
                activeUsers.pop();
                break;
            }
        }
    }

    function initializeEpochZero(uint256 _startBlock) external onlyOwner {
        uint256 endBlock = _startBlock + epochDuration;
        epochs[0] = Epoch({
            startBlock: _startBlock,
            endBlock: endBlock,
            totalSupplyAtStart: 0
        });
    }

    function finalizeEpoch() external onlyOwner {
        Epoch memory epoch = epochs[currentEpochId];
        require(epoch.startBlock != 0, "Epoch not initialized.");
        require(block.number > epoch.endBlock, "Epoch has not ended.");

        EpochRewards storage epochRewards = epochRewardsInfo[currentEpochId];

        if (currentEpochId > 0) {
            for (uint i = 0; i < rewardTokenAddresses.length; i++) {
                address token = rewardTokenAddresses[i];
                RewardToken storage rewardToken = rewardTokens[token];
                if (rewardToken.epochsLeft == 0) {
                    continue;
                }
                uint256 rewards = rewardToken.availableRewards /
                    rewardToken.epochsLeft;
                rewardToken.availableRewards -= rewards;
                rewardToken.epochsLeft--;

                epochRewards.rewardTokens.push(token);
                epochRewards.rewardAmounts.push(rewards);
                epochRewards.rewardsClaimed.push(0);
            }
        }
        currentEpochId++;
        Epoch storage nextEpoch = epochs[currentEpochId];
        nextEpoch.startBlock = block.number;
        nextEpoch.endBlock = block.number + epochDuration;
        nextEpoch.totalSupplyAtStart = totalSupply();
        emit EpochFinalized(currentEpochId - 1);
    }

    ////////////////// MAIN //////////////////

    /// @notice Users Deposit tokens to our vault
    /**
     * @dev Anyone can call this function up to total number of users.
     *      Users must approve deposit token before calling this function.
     *      We mint represent token to users so that we can calculate each users weighted deposit amount.
     */
    /// @param _amount Token Amount to deposit
    function lockTokens(uint _amount) external nonReentrant {
        require(_amount >= MIN_LOCK_AMOUNT, "Amount below minimum requirement");
        require(
            activeUsers.length <= maxActiveUsers,
            "Max users limit reached"
        );
        require(
            vaultToken.balanceOf(msg.sender) >= _amount,
            "Insufficient ERC20 balance"
        );
        require(
            userLockInfo[msg.sender].lockedTokens == 0,
            "Tokens already locked"
        );
        require(
            vaultToken.allowance(msg.sender, address(this)) >= _amount,
            "Insufficient allowance"
        );

        uint feeAmount = (_amount * DEPOSIT_FEE_PERCENT) / 100; // Calculate the fee
        uint netAmount = _amount - feeAmount; // Calculate net amount after fee deduction

        // Transfer the fee and the net amount
        vaultToken.safeTransferFrom(msg.sender, feeBeneficiary, feeAmount);
        vaultToken.safeTransferFrom(msg.sender, address(this), netAmount);

        // Manage active users
        activeUsers.push(msg.sender);

        userLockInfo[msg.sender] = UserLock(
            netAmount,
            netAmount,
            block.number,
            block.number + LOCK_PERIOD,
            0
        );
        totalLockedTokens += netAmount;

        emit Transfer(address(0), msg.sender, 0);
        emit TokensLocked(
            msg.sender,
            netAmount,
            userLockInfo[msg.sender].lockEndBlock
        );
    }

    /// @notice Allows users to extend their lock period and add more tokens to the lock
    /// @param _additionalAmount The additional amount of tokens to lock
    function extendLock(uint256 _additionalAmount) external nonReentrant {
        UserLock storage lock = userLockInfo[msg.sender];

        require(block.number < lock.lockEndBlock, "Lock has already ended");
        require(lock.lockedTokens > 0, "No active lock found");

        if (_additionalAmount > 0) {
            // If additional amount is greater than 0 it is intended as a new lock, history will be lost.
            require(
                _additionalAmount >= MIN_LOCK_AMOUNT,
                "Amount below minimum requirement"
            );
            require(
                vaultToken.balanceOf(msg.sender) >= _additionalAmount,
                "Insufficient ERC20 balance"
            );
            require(
                vaultToken.allowance(msg.sender, address(this)) >=
                    _additionalAmount,
                "Insufficient allowance"
            );

            uint256 feeAmount = (_additionalAmount * DEPOSIT_FEE_PERCENT) / 100;
            uint256 netAmount = _additionalAmount - feeAmount;

            vaultToken.safeTransferFrom(msg.sender, feeBeneficiary, feeAmount);
            vaultToken.safeTransferFrom(msg.sender, address(this), netAmount);

            // Increase locked tokens amount
            totalLockedTokens += netAmount;
            lock.lockedTokens += netAmount;
            lock.virtualLockedTokens = lock.lockedTokens;
            lock.lockStartBlock = block.number;
            lock.lockEndBlock = block.number + LOCK_PERIOD;

            emit TokensLocked(
                msg.sender,
                netAmount,
                userLockInfo[msg.sender].lockEndBlock
            );
        } else {
            // calculate the new virtual principal
            uint elapsedTime = block.number - lock.lockStartBlock;
            uint totalDuration = lock.lockEndBlock - lock.lockStartBlock;
            uint virtualPrincipal = lock.lockedTokens +
                (lock.lockedTokens * elapsedTime) /
                totalDuration;

            lock.virtualLockedTokens = virtualPrincipal;
            lock.lockEndBlock = block.number + LOCK_PERIOD;

            emit LockExtended(msg.sender, _additionalAmount, lock.lockEndBlock);
        }
    }

    /// @notice Function to fund rewards
    /// @param token Address of the token
    /// @param amount Amount of tokens to fund
    function fundRewards(
        address token,
        uint numberEpochs,
        uint amount
    ) external nonReentrant onlyOwner {
        require(
            rewardTokens[token].tokenAddress != address(0),
            "Token not added as a reward token"
        );

        if (numberEpochs > 0) {
            rewardTokens[token].epochsLeft += numberEpochs;
        }

        if (amount > 0) {
            require(
                IERC20(token).balanceOf(msg.sender) >= amount,
                "Insufficient balance"
            );

            require(
                IERC20(token).allowance(msg.sender, address(this)) >= amount,
                "Check the token allowance. Approval required."
            );

            // Transfer the funds from the owner to the contract
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // Update total available rewards for the specified token
            rewardTokens[token].availableRewards += amount;
        }

        emit RewardsFunded(token, amount, numberEpochs);
    }

    /// @notice Emergency unlock function to unlock tokens
    /// @param user Address of the user
    // What about the rewards?
    function emergencyUnlock(address user) external nonReentrant onlyOwner {
        require(
            block.number >
                userLockInfo[user].lockEndBlock + 30 * BLOCKS_PER_DAY,
            "Emergency unlock time restriction not met"
        );

        uint amount = userLockInfo[user].lockedTokens;
        delete userLockInfo[user];
        totalLockedTokens -= amount;
        _removeActiveUser(user);

        vaultToken.safeTransfer(user, amount);
        emit EmergencyUnlockTriggered(user, amount);
    }

    /// @notice Claim unlocked tokens
    function unlockTokens() external nonReentrant {
        require(
            block.number > userLockInfo[msg.sender].lockEndBlock,
            "Tokens are still locked"
        );
        require(
            userLockInfo[msg.sender].lockedTokens > 0,
            "No locked tokens to claim"
        );

        uint amount = userLockInfo[msg.sender].lockedTokens;
        delete userLockInfo[msg.sender];
        totalLockedTokens -= amount;
        _removeActiveUser(msg.sender);

        vaultToken.safeTransfer(msg.sender, amount);
        emit TokensUnlocked(msg.sender, amount);
    }

    function claimRewards() external {
        uint256 _epochId = userLockInfo[msg.sender].lastClaimedEpoch + 1;
        require(_epochId < currentEpochId, "Rewards already claimed");
        require(
            userLockInfo[msg.sender].lockedTokens > 0,
            "No locked tokens found"
        );

        EpochRewards storage epochRewards = epochRewardsInfo[_epochId];
        for (uint i = 0; i < epochRewards.rewardTokens.length; i++) {
            // get the epoch start block
            uint256 userRewards = (epochRewards.rewardAmounts[i] *
                balanceOfAt(msg.sender, epochs[_epochId].startBlock)) /
                epochs[_epochId].totalSupplyAtStart;
            epochRewards.rewardsClaimed[i] += userRewards;
            IERC20(epochRewards.rewardTokens[i]).safeTransfer(
                msg.sender,
                userRewards
            );
        }

        userLockInfo[msg.sender].lastClaimedEpoch = _epochId;
        emit RewardsClaimed(msg.sender, _epochId);
    }

    /// @notice Withdraw ERC-20 Token to the owner
    /// @param _tokenContract ERC-20 Token address
    function withdrawERC20(
        address _tokenContract
    ) external nonReentrant onlyOwner {
        require(
            _tokenContract != address(vaultToken),
            "Cannot withdraw the vaultToken"
        );
        require(
            rewardTokens[_tokenContract].tokenAddress == address(0),
            "Cannot withdraw reward tokens"
        );

        uint balance = IERC20(_tokenContract).balanceOf(address(this));

        if (balance > 0) {
            // Withdraw the entire balance if it's not a reward token
            IERC20(_tokenContract).safeTransfer(msg.sender, balance);
        }

        emit ERC20Withdrawn(_tokenContract, balance);
    }
}
