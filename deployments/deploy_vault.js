async function main() {
    const Vault = await ethers.getContractFactory("Vault");
    const vault = await Vault.deploy(
        "0x64358a8Dd8AabEb7181be9d4341AC2aD87Fd8bC2", // _token
        100, // _depositFeeRate (example value, adjust as needed)
        "0xYourVaultAdminAddress", // _vaultAdmin (replace with actual admin address)
        "0xYourFactoryAddress", // _factory (replace with actual factory address)
        "0xYourFeeBeneficiaryAddress" // _feeBeneficiary (replace with actual fee beneficiary address)
    );
    console.log("Vault Contract Deployed to Address:", vault.address);
}
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
