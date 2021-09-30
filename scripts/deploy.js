async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  console.log("Account balance:", (await deployer.getBalance()).toString());

  const StakingV2 = await ethers.getContractFactory("StakingV2");
  const stakingV2 = await StakingV2.deploy();

  console.log("StakingV2 address:", stakingV2.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
