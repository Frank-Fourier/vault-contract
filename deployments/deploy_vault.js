async function main() {
    const HelloWorld = await ethers.getContractFactory("Vault");
    const hello_world = await HelloWorld.deploy("0x64358a8Dd8AabEb7181be9d4341AC2aD87Fd8bC2", "0x33B7D46c8Ee49C7781A01CbAc18535F9A65dB642","0x64358a8Dd8AabEb7181be9d4341AC2aD87Fd8bC2");
    console.log("Contract Deployed to Address:", hello_world.address);
}
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
