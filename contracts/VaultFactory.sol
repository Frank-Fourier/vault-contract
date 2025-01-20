// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./dependencies/Ownable.sol";
import "./Vault.sol";

/**
 * @title VaultFactory
 * @dev A factory contract for creating and managing `Vault` instances.
 */
contract VaultFactory is Ownable, ReentrancyGuard {
    /// @notice List of approved partners
    mapping(address => bool) public approvedPartners;
    /// @notice Address of the main Vault
    address public mainVaultAddress;
    /// @notice Address of the main fee beneficiary
    address public mainFeeBeneficiary;
    /// @notice List of all deployed Vaults
    Vault[] public deployedVaults;

    /// @notice Event emitted when a new Vault is created
    event VaultCreated(address indexed creator, address indexed vaultAddress);
    /// @notice Event emitted when a partner is approved or removed
    event PartnerApprovalChanged(address indexed partner, bool approved);
    /// @notice Event emitted when fee beneficiaries are updated in the Vault
    event FeeBeneficiaryUpdated(address indexed newFeeBeneficiary);

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
        address _mainFeeBeneficiary,
    ) {
        require(_mainVaultAddress != address(0), "Invalid main vault address");
        require(_mainFeeBeneficiary != address(0), "Invalid main fee beneficiary");
        require(_owner != address(0), "Invalid owner address");

        transferOwnership(_owner);

        mainVaultAddress = _mainVaultAddress;
        mainFeeBeneficiary = _mainFeeBeneficiary;
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
     * @return Address of the newly deployed Vault.
     */
    function createVault(
        address _vaultToken,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _feeBeneficiary,
    ) external nonReentrant returns (address) {
        require(approvedPartners[msg.sender], "VaultFactory: not an approved partner");
        require(_vaultToken != address(0), "VaultFactory: invalid token address");
        require(_vaultAdmin != address(0), "VaultFactory: invalid admin address");
        require(_feeBeneficiary != address(0), "VaultFactory: invalid fee address");

        Vault newVault = new Vault(
            _vaultToken,
            _depositFeeRate,
            _vaultAdmin,
            address(this), // Pass the factory's address
            _feeBeneficiary
        );

        deployedVaults.push(newVault);

        emit VaultCreated(msg.sender, address(newVault));
        return address(newVault);
    }

    /**
     * @dev Returns the number of deployed Vaults.
     * @return The total number of deployed Vaults.
     */
    function getDeployedVaultsCount() external view returns (uint256) {
        return deployedVaults.length;
    }
}