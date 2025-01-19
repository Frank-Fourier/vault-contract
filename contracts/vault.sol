// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Vault is ERC721, ERC721Enumerable, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct Lock {
        uint256 amount;
        uint256 startTimestamp; // Added start timestamp
        uint256 endTimestamp;   // Changed from 'end' to 'endTimestamp'
        uint256 multiplier;
        uint256 lastRewardEpoch;
    }

    uint256 public constant MIN_LOCK_AMOUNT = 1_000 * 10 ** 18;
    uint256 public constant MAX_LOCK_DURATION = 52 weeks;
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;

    uint256 public maxActiveUsers = 1_000;
    uint256 public epochDuration;
    uint256 public currentEpochId;

    address public partnerFeeBeneficiary;
    address public mainFeeBeneficiary;
    address public projectFundAddress;

    IERC20 public immutable vaultToken;

    mapping(uint256 => Lock) public locks;
    mapping(uint256 => mapping(address => uint256)) public epochRewards; // epochId => tokenAddress => rewardAmount

    uint256 private _nextTokenId;
    address[] public rewardTokenAddresses;

    event TokensLocked(address indexed user, uint256 tokenId, uint256 amount, uint256 lockEndTimestamp);
    event TokensUnlocked(address indexed user, uint256 tokenId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 tokenId, uint256 epochId);
    event EpochAdvanced(uint256 indexed epochId);
    event RewardsFunded(address indexed token, uint256 amount);
    event FeeBeneficiariesUpdated(address partnerFeeBeneficiary, address mainFeeBeneficiary, address projectFundAddress);

    modifier onlyOwnerOrPartner() {
        require(msg.sender == owner() || msg.sender == partnerFeeBeneficiary, "Caller is not the owner or partner");
        _;
    }

    constructor(
        address _vaultToken,
        address _partnerFeeBeneficiary,
        address _mainFeeBeneficiary,
        address _projectFundAddress,
        uint256 _epochDuration,
        address _owner
    ) ERC721("Vault Lock NFT", "vLOCK") {
        require(_vaultToken != address(0), "Invalid vault token address");
        require(_partnerFeeBeneficiary != address(0), "Invalid partner fee beneficiary address");
        require(_mainFeeBeneficiary != address(0), "Invalid main fee beneficiary address");
        require(_projectFundAddress != address(0), "Invalid project fund address");
        require(_epochDuration > 0, "Invalid epoch duration");
        require(_owner != address(0), "Invalid owner address");

        vaultToken = IERC20(_vaultToken);
        partnerFeeBeneficiary = _partnerFeeBeneficiary;
        mainFeeBeneficiary = _mainFeeBeneficiary;
        projectFundAddress = _projectFundAddress;
        epochDuration = _epochDuration;
        transferOwnership(_owner); // Set the owner of the vault

        // Initialize the first epoch
        currentEpochId = 1;
        epochRewards[currentEpochId][_vaultToken] = 0; // Initialize with zero rewards
        rewardTokenAddresses.push(_vaultToken);
    }

    /*** Locking Functions ***/

    function lockTokens(uint256 _amount, uint256 _lockDuration) external nonReentrant whenNotPaused returns (uint256) {
        require(_amount >= MIN_LOCK_AMOUNT, "Amount below minimum requirement");
        require(totalSupply() < maxActiveUsers, "Max users limit reached");
        require(vaultToken.balanceOf(msg.sender) >= _amount, "Insufficient ERC20 balance");
        require(vaultToken.allowance(msg.sender, address(this)) >= _amount, "Insufficient allowance");
        require(_lockDuration >= MIN_LOCK_DURATION, "Lock duration too short");
        require(_lockDuration <= MAX_LOCK_DURATION, "Lock duration too long");

        // Fee Splitting
        uint256 partnerFee = (_amount * 6) / 1000; // 0.6%
        uint256 mainFee = (_amount * 4) / 1000;    // 0.4%
        uint256 adminFee = (_amount * 3) / 1000;   // 0.3%
        uint256 netAmount = _amount - partnerFee - mainFee - adminFee;

        vaultToken.safeTransferFrom(msg.sender, partnerFeeBeneficiary, partnerFee);
        vaultToken.safeTransferFrom(msg.sender, mainFeeBeneficiary, mainFee);
        vaultToken.safeTransferFrom(msg.sender, projectFundAddress, adminFee);
        vaultToken.safeTransferFrom(msg.sender, address(this), netAmount);

        uint256 lockEndTimestamp = block.timestamp + _lockDuration; // Use timestamp for lock end
        uint256 multiplier = calculateMultiplier(_lockDuration);

        _nextTokenId++;
        uint256 tokenId = _nextTokenId;
        _safeMint(msg.sender, tokenId);

        locks[tokenId] = Lock({
            amount: netAmount,
            startTimestamp: block.timestamp, // Set start timestamp
            endTimestamp: lockEndTimestamp,  // Set end timestamp
            multiplier: multiplier,
            lastRewardEpoch: currentEpochId - 1 // Start claiming from the next epoch
        });

        emit TokensLocked(msg.sender, tokenId, netAmount, lockEndTimestamp);
        return tokenId;
    }

    function unlockTokens(uint256 _tokenId) external nonReentrant whenNotPaused {
        require(ownerOf(_tokenId) == msg.sender, "Not the owner of the lock");
        Lock storage userLock = locks[_tokenId];
        require(block.timestamp >= userLock.endTimestamp, "Lock period not ended");

        uint256 amount = userLock.amount;
        delete locks[_tokenId];

        _burn(_tokenId);
        vaultToken.safeTransfer(msg.sender, amount);

        emit TokensUnlocked(msg.sender, _tokenId, amount);
    }

    /*** Reward Functions ***/

    function fundRewards(address _rewardToken, uint256 _amount) external nonReentrant onlyOwnerOrPartner {
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_amount > 0, "Amount must be greater than zero");

        // Transfer reward tokens to the contract
        IERC20(_rewardToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Add to the current epoch's rewards
        epochRewards[currentEpochId][_rewardToken] += _amount;

        // Add to reward tokens array if not already added
        bool tokenExists = false;
        for (uint256 i = 0; i < rewardTokenAddresses.length; i++) {
            if (rewardTokenAddresses[i] == _rewardToken) {
                tokenExists = true;
                break;
            }
        }
        if (!tokenExists) {
            rewardTokenAddresses.push(_rewardToken);
        }

        emit RewardsFunded(_rewardToken, _amount);
    }

    function claimRewards(uint256 _tokenId) external nonReentrant whenNotPaused {
        require(ownerOf(_tokenId) == msg.sender, "Not the owner of the lock");
        Lock storage userLock = locks[_tokenId];
        require(userLock.lastRewardEpoch < currentEpochId, "No new rewards to claim");

        uint256 totalVotingPower = getTotalVotingPowerAtEpoch(userLock.lastRewardEpoch + 1);

        for (uint256 epoch = userLock.lastRewardEpoch + 1; epoch <= currentEpochId; epoch++) {
            for (uint256 i = 0; i < rewardTokenAddresses.length; i++) {
                address rewardToken = rewardTokenAddresses[i];
                uint256 rewardAmount = epochRewards[epoch][rewardToken];
                uint256 userVotingPower = votingPowerAtEpoch(_tokenId, epoch);
                uint256 userReward = (rewardAmount * userVotingPower) / totalVotingPower;
                if (userReward > 0) {
                    IERC20(rewardToken).safeTransfer(msg.sender, userReward);
                }
            }
        }
        userLock.lastRewardEpoch = currentEpochId;

        emit RewardsClaimed(msg.sender, _tokenId, currentEpochId);
    }

    /*** Epoch Management ***/

    function advanceEpoch() external onlyOwnerOrPartner {
        currentEpochId++;
        emit EpochAdvanced(currentEpochId);
    }

    /*** Voting Power Functions ***/

    function calculateMultiplier(uint256 _lockDuration) internal pure returns (uint256) {
        // Linear increase from 1x to 2.5x over the maximum lock period
        return 10000 + (_lockDuration * 15000) / MAX_LOCK_DURATION;
    }

    function votingPower(uint256 _tokenId) public view returns (uint256) {
        Lock storage userLock = locks[_tokenId];
        if (block.timestamp >= userLock.endTimestamp) return 0;

        uint256 timeElapsed = block.timestamp - userLock.startTimestamp;
        uint256 totalLockTime = userLock.endTimestamp - userLock.startTimestamp;
        uint256 timeRemaining = userLock.endTimestamp - block.timestamp;

        // Calculate the decaying multiplier
        uint256 decayedMultiplier = (userLock.multiplier * timeRemaining) / totalLockTime;

        return (userLock.amount * decayedMultiplier) / 10000;
    }

    function votingPowerAtEpoch(uint256 _tokenId, uint256 _epochId) public view returns (uint256) {
        // For simplicity, assuming voting power doesn't change within an epoch
        return votingPower(_tokenId);
    }

    function totalVotingPower(address _user) public view returns (uint256) {
        uint256 total = 0;
        uint256 balance = balanceOf(_user);
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(_user, i);
            total += votingPower(tokenId);
        }
        return total;
    }

    function getTotalVotingPowerAtEpoch(uint256 _epochId) public view returns (uint256) {
        // Implement logic to calculate total voting power at a specific epoch
        // For simplicity, returning a placeholder value
        return 1e24; // Example total voting power
    }

    /*** Fee Beneficiary Functions ***/

    function setFeeBeneficiaries(
        address _partnerFeeBeneficiary,
        address _mainFeeBeneficiary,
        address _projectFundAddress
    ) external onlyOwner {
        require(_partnerFeeBeneficiary != address(0), "Invalid partner fee beneficiary");
        require(_mainFeeBeneficiary != address(0), "Invalid main fee beneficiary");
        require(_projectFundAddress != address(0), "Invalid project fund address");

        partnerFeeBeneficiary = _partnerFeeBeneficiary;
        mainFeeBeneficiary = _mainFeeBeneficiary;
        projectFundAddress = _projectFundAddress;

        emit FeeBeneficiariesUpdated(_partnerFeeBeneficiary, _mainFeeBeneficiary, _projectFundAddress);
    }

    /*** Administrative Functions ***/

    function setMaxActiveUsers(uint256 _newMax) external onlyOwner {
        require(_newMax > 0, "Invalid max active users");
        maxActiveUsers = _newMax;
    }

    function setEpochDuration(uint256 _newDuration) external onlyOwner {
        require(_newDuration > 0, "Invalid epoch duration");
        epochDuration = _newDuration;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(vaultToken), "Cannot withdraw vault token");
        IERC20(_token).safeTransfer(owner(), _amount);
    }

    /*** Overridden ERC721 Functions ***/

    // Prevent transfers of NFTs
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Enumerable)
        whenNotPaused
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        require(from == address(0) || to == address(0), "Transfers are disabled");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
