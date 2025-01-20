async function main() {
    const VaultFactory = await ethers.getContractFactory("VaultFactory");
    const factory = await VaultFactory.deploy(
        "0xYourOwnerAddress", // _owner (replace with actual owner address)
        "0xYourMainVaultAddress", // _mainVaultAddress (replace with actual main vault address)
        "0xYourMainFeeBeneficiaryAddress" // _mainFeeBeneficiary (replace with actual main fee beneficiary address)
    );
    console.log("VaultFactory Contract Deployed to Address:", factory.address);
}
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
