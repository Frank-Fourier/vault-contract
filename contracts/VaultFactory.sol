// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IVaultFactory.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultDeployer.sol";

/**
 * @title VaultFactory
 * @dev A factory contract for creating and managing `Vault` instances with tier-based fee structures.
 */
contract VaultFactory is Ownable, ReentrancyGuard {
    // Enums and Structs are now inherited from the interface and removed from here.

    /// @notice Mapping of approved partners
    mapping(address => bool) public approvedPartners; // at some point we can disable the whitelist so that anyone can create a vault
    /// @notice Whitelist for partners is active or not
    bool public partnerWhitelistActive;
    /// @notice Address of the main Vault
    address public mainVaultAddress;
    /// @notice Address of the main fee beneficiary
    address public mainFeeBeneficiary;
    /// @notice List of all deployed Vaults
    address[] public deployedVaults;
    /// @notice Address of the VaultDeployer contract
    IVaultDeployer public vaultDeployer;
    /// @notice Address of the master Vault implementation contract
    address public vaultImplementation;
    /// @notice Mapping from vault address to its tier
    mapping(address => IVaultFactory.VaultTier) public vaultTiers;
    /// @notice Tier configurations mapping
    mapping(IVaultFactory.VaultTier => IVaultFactory.TierConfig) public tierConfigs;
    /// @notice Total deployment fees collected
    uint256 public totalDeploymentFeesCollected;

    /// @notice Event emitted when a new Vault is created
    /// @param creator The address that created the vault
    /// @param vaultAddress The address of the newly created vault
    /// @param tier The tier of the vault
    /// @param deploymentFeePaid The deployment fee paid
    event VaultCreated(
        address indexed creator, 
        address indexed vaultAddress, 
        IVaultFactory.VaultTier tier,
        uint256 deploymentFeePaid
    );

    /// @notice Event emitted when the vault implementation address is updated
    /// @param implementation The address of the new implementation
    event VaultImplementationUpdated(address indexed implementation);

    /// @notice Event emitted when the vault deployer address is updated
    /// @param deployer The address of the new deployer
    event VaultDeployerUpdated(address indexed deployer);

    /// @notice Event emitted when partner whitelist status is changed
    /// @param active Whether the whitelist is active
    event PartnerWhitelistStatusChanged(bool active);
    /// @notice Event emitted when a partner is approved or removed
    /// @param partner The address of the partner
    /// @param approved Whether the partner is approved
    event PartnerApprovalChanged(address indexed partner, bool approved);

    /// @notice Event emitted when fee beneficiary is updated
    /// @param newFeeBeneficiary The address of the new fee beneficiary
    event FeeBeneficiaryUpdated(address indexed newFeeBeneficiary);

    /// @notice Event emitted when tier configuration is updated
    /// @param tier The tier that was updated
    event TierConfigUpdated(IVaultFactory.VaultTier indexed tier);

    /// @notice Event emitted when deployment fees are withdrawn
    /// @param to The address that received the fees
    /// @param amount The amount of fees withdrawn
    event DeploymentFeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Event emitted when a vault tier is upgraded
    /// @param vaultAddress The address of the vault that was upgraded
    /// @param oldTier The previous tier
    /// @param newTier The new tier
    /// @param upgradeCost The cost of the upgrade
    event VaultTierUpgraded(
        address indexed vaultAddress,
        IVaultFactory.VaultTier indexed oldTier,
        IVaultFactory.VaultTier indexed newTier,
        uint256 upgradeCost
    );

    /// @notice Modifier to restrict access to approved partners
    modifier onlyApprovedPartner() {
        require(approvedPartners[msg.sender], "V.F.1");
        _;
    }

    /*
     * ==========  CONSTRUCTOR  ==========
     */

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
        require(_mainVaultAddress != address(0), "V.F.2");
        require(_mainFeeBeneficiary != address(0), "V.F.3");
        require(_owner != address(0), "V.F.4");

        mainVaultAddress = _mainVaultAddress;
        mainFeeBeneficiary = _mainFeeBeneficiary;
        approvedPartners[_owner] = true;
        partnerWhitelistActive = true;

        // Initialize tier configurations
        _initializeTierConfigs();
    }

    /*
     * ==========  MAIN FUNCTIONS  ==========
     */

        /**
     * @dev Deploys a new Vault contract.
     * @param _vaultToken Address of the ERC20 token to lock in the Vault.
     * @param _depositFeeRate Fee rate in basis points (e.g., 100 = 1%).
     * @param _vaultAdmin Address of the Vault admin.
     * @param _feeBeneficiary Address of the Vault fee beneficiary.
     * @param _tier The tier of the Vault to create.
     * @return The address of the newly deployed Vault.
     */
    function createVault(
        address _vaultToken,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _feeBeneficiary,
        IVaultFactory.VaultTier _tier
    ) external payable nonReentrant returns (address) {
        if (partnerWhitelistActive) {
            require(approvedPartners[msg.sender], "V.F.1");
        }
        require(_vaultToken != address(0), "V.F.5");
        require(_vaultAdmin != address(0), "V.F.6");
        require(_feeBeneficiary != address(0), "V.F.7");
        require(address(vaultDeployer) != address(0), "V.F.25");
        require(vaultImplementation != address(0), "V.F.26");

        IVaultFactory.TierConfig memory tierConfig = tierConfigs[_tier];
        
        // Check deployment fee
        require(msg.value >= tierConfig.deploymentFee, "V.F.8");
        
        // Validate deposit fee rate
        require(
            _depositFeeRate >= tierConfig.minDepositFeeRate && 
            _depositFeeRate <= tierConfig.maxDepositFeeRate, 
            "V.F.9"
        );

        // Prepare initialization call for the Vault's initialize function
        bytes memory initializeData = abi.encodeWithSelector(
            IVault.initialize.selector,
            _vaultToken,
            _depositFeeRate,
            _vaultAdmin,
            address(this),
            _feeBeneficiary,
            _tier
        );

        // Create vault clone via the deployer
        address newVaultAddress = vaultDeployer.deployVault(
            vaultImplementation,
            initializeData
        );

        deployedVaults.push(newVaultAddress);
        vaultTiers[newVaultAddress] = _tier;
        
        // Track deployment fees
        totalDeploymentFeesCollected += tierConfig.deploymentFee;
        
        // Refund excess payment
        if (msg.value > tierConfig.deploymentFee) {
            payable(msg.sender).transfer(msg.value - tierConfig.deploymentFee);
        }

        emit VaultCreated(msg.sender, newVaultAddress, _tier, tierConfig.deploymentFee);
        return newVaultAddress;
    }

    /**
     * @dev Allows vault admin to upgrade their vault to a higher tier.
     * @param _vaultAddress Address of the vault to upgrade.
     * @param _newTier The new tier to upgrade to.
     */
    function upgradeVaultTier(address _vaultAddress, IVaultFactory.VaultTier _newTier) external payable nonReentrant {
        // Verify vault exists and caller is the vault admin
        require(vaultTiers[_vaultAddress] != IVaultFactory.VaultTier(0) || _vaultAddress != address(0), "V.F.10");
        
        IVault vault = IVault(_vaultAddress);
        require(msg.sender == vault.owner(), "V.F.11");
        
        IVaultFactory.VaultTier currentTier = vaultTiers[_vaultAddress];
        require(_newTier > currentTier, "V.F.12");
        
        // Calculate upgrade cost
        IVaultFactory.TierConfig memory currentConfig = tierConfigs[currentTier];
        IVaultFactory.TierConfig memory newConfig = tierConfigs[_newTier];
        uint256 upgradeCost = newConfig.deploymentFee - currentConfig.deploymentFee;
        
        require(msg.value >= upgradeCost, "V.F.13");
        
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

    /*
     * ==========  READ FUNCTIONS  ==========
     */

    /**
     * @notice Get tier configuration for a vault.
     * @param _vaultAddress Address of the vault.
     * @return The tier configuration for the vault.
     */
    function getVaultTierConfig(address _vaultAddress) 
        external 
        view 
        returns (IVaultFactory.TierConfig memory) 
    {
        return tierConfigs[vaultTiers[_vaultAddress]];
    }

    /**
     * @notice Calculate performance fee for a given amount and vault.
     * @param _vaultAddress Address of the vault.
     * @param _rewardAmount Amount of rewards to calculate fee for.
     * @return The performance fee amount.
     */
    function calculatePerformanceFee(address _vaultAddress, uint256 _rewardAmount) 
        external 
        view 
        returns (uint256) 
    {
        IVaultFactory.TierConfig memory config = tierConfigs[vaultTiers[_vaultAddress]];
        return (_rewardAmount * config.performanceFeeRate) / 10000;
    }

    /**
     * @notice Calculate deposit fee sharing for a vault.
     * @param _vaultAddress Address of the vault.
     * @param _feeAmount Amount of fees to split.
     * @return platformShare The amount going to the platform.
     * @return adminShare The amount going to the vault admin.
     */
    function calculateDepositFeeSharing(address _vaultAddress, uint256 _feeAmount) 
        external 
        view 
        returns (uint256 platformShare, uint256 adminShare) 
    {
        IVaultFactory.TierConfig memory config = tierConfigs[vaultTiers[_vaultAddress]];
        platformShare = (_feeAmount * config.platformDepositShare) / 10000;
        adminShare = _feeAmount - platformShare;
    }

    /**
     * @notice Returns the number of deployed Vaults.
     * @return The total number of deployed Vaults.
     */
    function getDeployedVaultsCount() external view returns (uint256) {
        return deployedVaults.length;
    }

    /**
     * @notice Get the current tier of a vault.
     * @param _vaultAddress Address of the vault.
     * @return The current tier of the vault.
     */
    function getVaultTier(address _vaultAddress) external view returns (IVaultFactory.VaultTier) {
        return vaultTiers[_vaultAddress];
    }

    /**
     * @notice Get tier upgrade cost (difference between tiers).
     * @param _vaultAddress Address of the vault.
     * @param _newTier The tier to upgrade to.
     * @return The cost to upgrade to the new tier.
     */
    function getTierUpgradeCost(address _vaultAddress, IVaultFactory.VaultTier _newTier) external view returns (uint256) {
        IVaultFactory.VaultTier currentTier = vaultTiers[_vaultAddress];
        require(_newTier > currentTier, "V.F.12");
        
        IVaultFactory.TierConfig memory currentConfig = tierConfigs[currentTier];
        IVaultFactory.TierConfig memory newConfig = tierConfigs[_newTier];
        
        return newConfig.deploymentFee - currentConfig.deploymentFee;
    }

    /*
     * ==========  ADMIN FUNCTIONS  ==========
     */

    /**
     * @notice Updates tier configuration (only owner).
     * @param _tier The tier to update.
     * @param _deploymentFee The deployment fee in wei.
     * @param _performanceFeeRate The performance fee rate in basis points.
     * @param _minDepositFeeRate The minimum deposit fee rate in basis points.
     * @param _maxDepositFeeRate The maximum deposit fee rate in basis points.
     * @param _platformDepositShare The platform share of deposit fees in basis points.
     * @param _canAdjustDepositFee Whether the admin can adjust deposit fees.
     * @param _tierName The human readable tier name.
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
        require(_performanceFeeRate <= 2000, "V.F.14"); // Max 20%
        require(_maxDepositFeeRate <= 1000, "V.F.15"); // Max 10%
        require(_minDepositFeeRate <= _maxDepositFeeRate, "V.F.16");
        require(_platformDepositShare <= 10000, "V.F.17");

        tierConfigs[_tier] = IVaultFactory.TierConfig({
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
     * @notice Approves or removes a partner.
     * @param _partner Address of the partner to approve or remove.
     * @param _approved True to approve, false to remove.
     */
    function setPartnerApproval(address _partner, bool _approved) external onlyOwner {
        require(_partner != address(0), "V.F.18");
        approvedPartners[_partner] = _approved;
        emit PartnerApprovalChanged(_partner, _approved);
    }

    /**
     * @notice Enables or disables the partner whitelist for creating vaults.
     * @param _active True to enable the whitelist, false to disable.
     */
    function setPartnerWhitelistActive(bool _active) external onlyOwner {
        partnerWhitelistActive = _active;
        emit PartnerWhitelistStatusChanged(_active);
    }

    /**
     * @notice Sets the main Vault address.
     * @param _mainVaultAddress Address of the main Vault.
     */
    function setMainVaultAddress(address _mainVaultAddress) external onlyOwner {
        require(_mainVaultAddress != address(0), "V.F.19");
        require(_mainVaultAddress != mainVaultAddress, "V.F.20");
        mainVaultAddress = _mainVaultAddress;
    }

    /**
     * @notice Sets the VaultDeployer contract address.
     * @param _deployer Address of the VaultDeployer contract.
     */
    function setVaultDeployer(address _deployer) external onlyOwner {
        require(_deployer != address(0), "V.F.19");
        vaultDeployer = IVaultDeployer(_deployer);
        emit VaultDeployerUpdated(_deployer);
    }

    /**
     * @notice Sets the master Vault implementation address.
     * @param _implementation Address of the master Vault implementation.
     */
    function setVaultImplementation(address _implementation) external onlyOwner {
        require(_implementation != address(0), "V.F.19");
        vaultImplementation = _implementation;
        emit VaultImplementationUpdated(_implementation);
    }

    /**
     * @notice Updates the main fee beneficiary address.
     * @param _newFeeBeneficiary Address of the new fee beneficiary.
     */
    function setMainFeeBeneficiary(address _newFeeBeneficiary) external onlyOwner {
        require(_newFeeBeneficiary != address(0), "V.F.21");
        require(_newFeeBeneficiary != mainFeeBeneficiary, "V.F.22");
        mainFeeBeneficiary = _newFeeBeneficiary;
        emit FeeBeneficiaryUpdated(_newFeeBeneficiary);
    }

    /**
     * @notice Withdraw collected deployment fees (only owner).
     * @param _to Address to send the fees to.
     */
    function withdrawDeploymentFees(address _to) external onlyOwner {
        require(_to != address(0), "V.F.23");
        uint256 balance = address(this).balance;
        require(balance > 0, "V.F.24");
        
        payable(_to).transfer(balance);
        emit DeploymentFeesWithdrawn(_to, balance);
    }

    /*
     * ==========  INTERNAL FUNCTIONS  ==========
     */

    /**
     * @dev Initializes the default tier configurations.
     */
    function _initializeTierConfigs() internal {
        // Model 1: "No Risk No Crown"
        tierConfigs[IVaultFactory.VaultTier.NO_RISK_NO_CROWN] = IVaultFactory.TierConfig({
            deploymentFee: 0,
            performanceFeeRate: 1000,        // 10%
            minDepositFeeRate: 500,          // 5%
            maxDepositFeeRate: 500,          // 5%
            platformDepositShare: 5000,      // 50%
            canAdjustDepositFee: false,
            tierName: "No Risk No Crown"
        });

        // Model 2: "Split the Spoils"
        tierConfigs[IVaultFactory.VaultTier.SPLIT_THE_SPOILS] = IVaultFactory.TierConfig({
            deploymentFee: 0.1 ether,
            performanceFeeRate: 500,         // 5%
            minDepositFeeRate: 100,          // 1%
            maxDepositFeeRate: 1000,         // 10%
            platformDepositShare: 5000,      // 50%
            canAdjustDepositFee: true,
            tierName: "Split the Spoils"
        });

        // Model 3: "Vaultmaster 3000"
        tierConfigs[IVaultFactory.VaultTier.VAULTMASTER_3000] = IVaultFactory.TierConfig({
            deploymentFee: 2 ether,
            performanceFeeRate: 150,         // 1.5%
            minDepositFeeRate: 0,            // 0%
            maxDepositFeeRate: 1000,         // 10%
            platformDepositShare: 0,         // 0% (admin keeps 100%)
            canAdjustDepositFee: true,
            tierName: "Vaultmaster 3000"
        });
    }

    /*
     * ==========  ERROR CODES  ==========
     * V.F.1: VaultFactory: not an approved partner
     * V.F.2: Invalid main vault address
     * V.F.3: Invalid main fee beneficiary
     * V.F.4: Invalid owner address
     * V.F.5: VaultFactory: invalid token address
     * V.F.6: VaultFactory: invalid admin address
     * V.F.7: VaultFactory: invalid fee address
     * V.F.8: Insufficient deployment fee
     * V.F.9: Invalid deposit fee rate for tier
     * V.F.10: VaultFactory: vault does not exist
     * V.F.11: VaultFactory: only vault admin can upgrade
     * V.F.12: VaultFactory: can only upgrade to higher tier
     * V.F.13: VaultFactory: insufficient upgrade fee
     * V.F.14: Performance fee too high
     * V.F.15: Deposit fee too high
     * V.F.16: Invalid fee range
     * V.F.17: Invalid platform share
     * V.F.18: VaultFactory: invalid partner address
     * V.F.19: VaultFactory: invalid address
     * V.F.20: VaultFactory: already set
     * V.F.21: VaultFactory: invalid fee beneficiary address
     * V.F.22: VaultFactory: same fee beneficiary
     * V.F.23: VaultFactory: invalid recipient
     * V.F.24: VaultFactory: no fees to withdraw
     * V.F.25: VaultFactory: deployer not set
     * V.F.26: VaultFactory: implementation not set
     */
}