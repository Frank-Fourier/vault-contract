// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Vault.sol";

/**
 * @title VaultFactory
 * @dev A factory contract for creating and managing `Vault` instances with tier-based fee structures.
 */
contract VaultFactory is Ownable, ReentrancyGuard {
    /// @notice Struct defining tier parameters
    struct TierConfig {
        uint256 deploymentFee;           // Deployment fee in wei
        uint256 performanceFeeRate;      // Performance fee in basis points
        uint256 minDepositFeeRate;       // Minimum deposit fee in basis points
        uint256 maxDepositFeeRate;       // Maximum deposit fee in basis points
        uint256 platformDepositShare;    // Platform share of deposit fees in basis points (10000 = 100%)
        bool    canAdjustDepositFee;     // Whether admin can adjust deposit fee
        string  tierName;                // Human readable tier name
    }

    /// @notice List of approved partners
    mapping(address => bool) public approvedPartners; // at some point we can disable the whitelist so that anyone can create a vault
    /// @notice Address of the main Vault
    address public mainVaultAddress;
    /// @notice Address of the main fee beneficiary
    address public mainFeeBeneficiary;
    /// @notice List of all deployed Vaults
    Vault[] public deployedVaults;
    /// @notice Mapping from vault address to its tier
    mapping(address => IVaultFactory.VaultTier) public vaultTiers;
    /// @notice Tier configurations
    mapping(IVaultFactory.VaultTier => TierConfig) public tierConfigs;
    /// @notice Total deployment fees collected
    uint256 public totalDeploymentFeesCollected;

    /// @notice Event emitted when a new Vault is created
    event VaultCreated(
        address indexed creator, 
        address indexed vaultAddress, 
        IVaultFactory.VaultTier tier,
        uint256 deploymentFeePaid
    );
    /// @notice Event emitted when a partner is approved or removed
    event PartnerApprovalChanged(address indexed partner, bool approved);
    /// @notice Event emitted when fee beneficiaries are updated
    event FeeBeneficiaryUpdated(address indexed newFeeBeneficiary);
    /// @notice Event emitted when tier configuration is updated
    event TierConfigUpdated(IVaultFactory.VaultTier indexed tier);
    /// @notice Event emitted when deployment fees are withdrawn
    event DeploymentFeesWithdrawn(address indexed to, uint256 amount);
    /// @notice Event emitted when a vault tier is upgraded
    event VaultTierUpgraded(
        address indexed vaultAddress,
        IVaultFactory.VaultTier indexed oldTier,
        IVaultFactory.VaultTier indexed newTier,
        uint256 upgradeCost
    );

    /// @notice Modifier to restrict access to approved deployers
    modifier onlyApprovedPartner() {
        require(approvedPartners[msg.sender], "Not an approved partner");
        _;
    }

    /**
     * @dev Initializes the factory with the main fee beneficiary.
     * @param _owner Address of the factory owner.
     * @param _mainVaultAddress Address of the main Vault
     * @param _mainFeeBeneficiary Address of the main fee beneficiary.
     */
    constructor(
        address _owner,
        address _mainVaultAddress,
        address _mainFeeBeneficiary
    ) Ownable(_owner) {
        require(_mainVaultAddress != address(0), "Invalid main vault address");
        require(_mainFeeBeneficiary != address(0), "Invalid main fee beneficiary");
        require(_owner != address(0), "Invalid owner address");

        mainVaultAddress = _mainVaultAddress;
        mainFeeBeneficiary = _mainFeeBeneficiary;
        approvedPartners[_owner] = true;

        // Initialize tier configurations
        _initializeTierConfigs();
    }

    /**
     * @dev Initializes the default tier configurations.
     */
    function _initializeTierConfigs() internal {
        // Model 1: "No Risk No Crown"
        tierConfigs[IVaultFactory.VaultTier.NO_RISK_NO_CROWN] = TierConfig({
            deploymentFee: 0,
            performanceFeeRate: 1000,        // 10%
            minDepositFeeRate: 500,          // 5%
            maxDepositFeeRate: 500,          // 5%
            platformDepositShare: 5000,      // 50%
            canAdjustDepositFee: false,
            tierName: "No Risk No Crown"
        });

        // Model 2: "Split the Spoils"
        tierConfigs[IVaultFactory.VaultTier.SPLIT_THE_SPOILS] = TierConfig({
            deploymentFee: 0.1 ether,
            performanceFeeRate: 500,         // 5%
            minDepositFeeRate: 100,          // 1%
            maxDepositFeeRate: 1000,         // 10%
            platformDepositShare: 5000,      // 50%
            canAdjustDepositFee: true,
            tierName: "Split the Spoils"
        });

        // Model 3: "Vaultmaster 3000"
        tierConfigs[IVaultFactory.VaultTier.VAULTMASTER_3000] = TierConfig({
            deploymentFee: 2 ether,
            performanceFeeRate: 150,         // 1.5%
            minDepositFeeRate: 0,            // 0%
            maxDepositFeeRate: 1000,         // 10%
            platformDepositShare: 0,         // 0% (admin keeps 100%)
            canAdjustDepositFee: true,
            tierName: "Vaultmaster 3000"
        });
    }

    /**
     * @dev Updates tier configuration (only owner).
     */
    function updateTierConfig(
        IVaultFactory.VaultTier _tier,
        uint256 _deploymentFee,
        uint256 _performanceFeeRate,
        uint256 _minDepositFeeRate,
        uint256 _maxDepositFeeRate,
        uint256 _platformDepositShare,
        bool _canAdjustDepositFee,
        string calldata _tierName
    ) external onlyOwner {
        require(_performanceFeeRate <= 2000, "Performance fee too high"); // Max 20%
        require(_maxDepositFeeRate <= 1000, "Deposit fee too high"); // Max 10%
        require(_minDepositFeeRate <= _maxDepositFeeRate, "Invalid fee range");
        require(_platformDepositShare <= 10000, "Invalid platform share");

        tierConfigs[_tier] = TierConfig({
            deploymentFee: _deploymentFee,
            performanceFeeRate: _performanceFeeRate,
            minDepositFeeRate: _minDepositFeeRate,
            maxDepositFeeRate: _maxDepositFeeRate,
            platformDepositShare: _platformDepositShare,
            canAdjustDepositFee: _canAdjustDepositFee,
            tierName: _tierName
        });

        emit TierConfigUpdated(_tier);
    }

    /**
     * @dev Approves or removes a partner.
     * @param partner Address of the partner to approve or remove.
     * @param approved True to approve, false to remove.
     */
    function setPartnerApproval(address partner, bool approved) external onlyOwner {
        require(partner != address(0), "VaultFactory: invalid partner address");
        approvedPartners[partner] = approved;
        emit PartnerApprovalChanged(partner, approved);
    }

    /**
     * @dev Updates the main fee beneficiary address.
     * @param _newFeeBeneficiary Address of the new fee beneficiary.
     */
    function setMainFeeBeneficiary(address _newFeeBeneficiary) external onlyOwner {
        require(_newFeeBeneficiary != address(0), "VaultFactory: invalid fee beneficiary address");
        require(_newFeeBeneficiary != mainFeeBeneficiary, "VaultFactory: same fee beneficiary");
        mainFeeBeneficiary = _newFeeBeneficiary;
        emit FeeBeneficiaryUpdated(_newFeeBeneficiary);
    }

    /**
     * @notice Sets the main Vault address.
     * @param _mainVaultAddress Address of the main Vault.
     */
    function setMainVaultAddress(address _mainVaultAddress) external onlyOwner {
        require(_mainVaultAddress != address(0), "Invalid address");
        require(_mainVaultAddress != mainVaultAddress, "Already set");
        mainVaultAddress = _mainVaultAddress;
    }

    /**
     * @dev Deploys a new Vault contract.
     * @param _vaultToken Address of the ERC20 token to lock in the Vault.
     * @param _depositFeeRate Fee rate in basis points (e.g., 100 = 1%).
     * @param _vaultAdmin Address of the Vault admin.
     * @param _feeBeneficiary Address of the Vault fee beneficiary.
     * @param _tier The tier of the Vault to create.
     * @return Address of the newly deployed Vault.
     */
    function createVault(
        address _vaultToken,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _feeBeneficiary,
        IVaultFactory.VaultTier _tier
    ) external payable nonReentrant returns (address) {
        require(approvedPartners[msg.sender], "VaultFactory: not an approved partner");
        require(_vaultToken != address(0), "VaultFactory: invalid token address");
        require(_vaultAdmin != address(0), "VaultFactory: invalid admin address");
        require(_feeBeneficiary != address(0), "VaultFactory: invalid fee address");

        TierConfig memory tierConfig = tierConfigs[_tier];
        
        // Check deployment fee
        require(msg.value >= tierConfig.deploymentFee, "Insufficient deployment fee");
        
        // Validate deposit fee rate
        require(
            _depositFeeRate >= tierConfig.minDepositFeeRate && 
            _depositFeeRate <= tierConfig.maxDepositFeeRate, 
            "Invalid deposit fee rate for tier"
        );

        // Create vault with tier information
        Vault newVault = new Vault(
            _vaultToken,
            _depositFeeRate,
            _vaultAdmin,
            address(this),
            _feeBeneficiary,
            _tier
        );

        deployedVaults.push(newVault);
        vaultTiers[address(newVault)] = _tier;
        
        // Track deployment fees
        totalDeploymentFeesCollected += tierConfig.deploymentFee;
        
        // Refund excess payment
        if (msg.value > tierConfig.deploymentFee) {
            payable(msg.sender).transfer(msg.value - tierConfig.deploymentFee);
        }

        emit VaultCreated(msg.sender, address(newVault), _tier, tierConfig.deploymentFee);
        return address(newVault);
    }

    /**
     * @dev Withdraw collected deployment fees (only owner).
     */
    function withdrawDeploymentFees(address _to) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        
        payable(_to).transfer(balance);
        emit DeploymentFeesWithdrawn(_to, balance);
    }

    /**
     * @dev Get tier configuration for a vault.
     */
    function getVaultTierConfig(address _vaultAddress) 
        external 
        view 
        returns (TierConfig memory) 
    {
        return tierConfigs[vaultTiers[_vaultAddress]];
    }

    /**
     * @dev Calculate performance fee for a given amount and vault.
     */
    function calculatePerformanceFee(address _vaultAddress, uint256 _rewardAmount) 
        external 
        view 
        returns (uint256) 
    {
        TierConfig memory config = tierConfigs[vaultTiers[_vaultAddress]];
        return (_rewardAmount * config.performanceFeeRate) / 10000;
    }

    /**
     * @dev Calculate deposit fee sharing for a vault.
     */
    function calculateDepositFeeSharing(address _vaultAddress, uint256 _feeAmount) 
        external 
        view 
        returns (uint256 platformShare, uint256 adminShare) 
    {
        TierConfig memory config = tierConfigs[vaultTiers[_vaultAddress]];
        platformShare = (_feeAmount * config.platformDepositShare) / 10000;
        adminShare = _feeAmount - platformShare;
    }

    /**
     * @dev Returns the number of deployed Vaults.
     * @return The total number of deployed Vaults.
     */
    function getDeployedVaultsCount() external view returns (uint256) {
        return deployedVaults.length;
    }

    /**
     * @dev Get the current tier of a vault.
     */
    function getVaultTier(address _vaultAddress) external view returns (IVaultFactory.VaultTier) {
        return vaultTiers[_vaultAddress];
    }

    /**
     * @dev Get tier upgrade cost (difference between tiers).
     */
    function getTierUpgradeCost(address _vaultAddress, IVaultFactory.VaultTier _newTier) external view returns (uint256) {
        IVaultFactory.VaultTier currentTier = vaultTiers[_vaultAddress];
        require(_newTier > currentTier, "VaultFactory: can only upgrade to higher tier");
        
        TierConfig memory currentConfig = tierConfigs[currentTier];
        TierConfig memory newConfig = tierConfigs[_newTier];
        
        return newConfig.deploymentFee - currentConfig.deploymentFee;
    }

    /**
     * @dev Allows vault admin to upgrade their vault to a higher tier.
     * @param _vaultAddress Address of the vault to upgrade.
     * @param _newTier The new tier to upgrade to.
     */
    function upgradeVaultTier(address _vaultAddress, IVaultFactory.VaultTier _newTier) external payable nonReentrant {
        // Verify vault exists and caller is the vault admin
        require(vaultTiers[_vaultAddress] != IVaultFactory.VaultTier(0) || _vaultAddress != address(0), "VaultFactory: vault does not exist");
        
        Vault vault = Vault(_vaultAddress);
        require(msg.sender == vault.owner(), "VaultFactory: only vault admin can upgrade");
        
        IVaultFactory.VaultTier currentTier = vaultTiers[_vaultAddress];
        require(_newTier > currentTier, "VaultFactory: can only upgrade to higher tier");
        
        // Calculate upgrade cost
        TierConfig memory currentConfig = tierConfigs[currentTier];
        TierConfig memory newConfig = tierConfigs[_newTier];
        uint256 upgradeCost = newConfig.deploymentFee - currentConfig.deploymentFee;
        
        require(msg.value >= upgradeCost, "VaultFactory: insufficient upgrade fee");
        
        // Update tier in factory
        vaultTiers[_vaultAddress] = _newTier;
        
        // Update tier in vault contract
        vault.updateVaultTier(_newTier);
        
        // Track additional deployment fees
        totalDeploymentFeesCollected += upgradeCost;
        
        // Refund excess payment
        if (msg.value > upgradeCost) {
            payable(msg.sender).transfer(msg.value - upgradeCost);
        }
        
        emit VaultTierUpgraded(_vaultAddress, currentTier, _newTier, upgradeCost);
    }
}