// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./dependencies/Ownable.sol";
import "./Vault.sol";

contract VaultFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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
    event FeeBeneficiaryUpdated(address mainFeeBeneficiary);

    /// @notice Modifier to restrict access to approved deployers
    modifier onlyApprovedPartner() {
        require(approvedPartners[msg.sender], "Not an approved partner");
        _;
    }

    /// @notice Constructor for the VaultFactory
    /// @param _owner Address of the owner
    /// @param _mainVaultAddress Address of the main Vault
    /// @param _mainFeeBeneficiary Address of the main fee beneficiary
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

    /// @notice Approve or remove partner
    /// @param partner Address of the partner to approve or remove
    /// @param approved True to approve, false to remove
    function setPartnerApproval(address partner, bool approved) external onlyOwner {
        require(partner != address(0), "Invalid address");
        approvedPartners[partner] = approved;
        emit PartnerApprovalChanged(partner, approved);
    }

    /// @notice Set the main fee beneficiary
    /// @param _mainFeeBeneficiary Address of the main fee beneficiary
    function setMainFeeBeneficiary(address _mainFeeBeneficiary) external onlyOwner {
        require(_mainFeeBeneficiary != address(0), "Invalid address");
        require(_mainFeeBeneficiary != mainFeeBeneficiary, "Already set");
        mainFeeBeneficiary = _mainFeeBeneficiary;
    }

    /// @notice Set the main Vault address
    /// @param _mainVaultAddress Address of the main Vault
    function setMainVaultAddress(address _mainVaultAddress) external onlyOwner {
        require(_mainVaultAddress != address(0), "Invalid address");
        require(_mainVaultAddress != mainVaultAddress, "Already set");
        mainVaultAddress = _mainVaultAddress;
    }

    /// @notice Deploy a new Vault contract
    /// @param _vaultToken Address of the ERC20 token to lock in the Vault
    /// @param _feeBeneficiary Address to receive fees
    /// @param _epochDuration Duration of each epoch in blocks
    /// @return address of the newly created Vault
    function createVault(
        address _vaultToken,
        address _feeBeneficiary,
        uint _epochDuration
    ) external onlyApprovedPartner returns (address) {
        require(_vaultToken != address(0), "Invalid token address");
        require(_feeBeneficiary != address(0), "Invalid beneficiary address");

        // Create a new Vault instance
        Vault newVault = new Vault(msg.sender, _vaultToken, _feeBeneficiary, _epochDuration);
        deployedVaults.push(newVault);

        emit VaultCreated(msg.sender, address(newVault));
        return address(newVault);
    }

    /// @notice Get the number of deployed Vaults
    /// @return uint representing the count of deployed Vaults
    function getDeployedVaultsCount() external view returns (uint) {
        return deployedVaults.length;
    }
}