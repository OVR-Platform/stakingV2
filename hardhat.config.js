require("@nomiclabs/hardhat-waffle");
require("solidity-coverage");
require("@nomiclabs/hardhat-solhint");
require("@nomiclabs/hardhat-web3");
require("@nomiclabs/hardhat-ethers");
// require('@openzeppelin/contracts');
require("@openzeppelin/hardhat-upgrades");
require("hardhat-gas-reporter");
require("hardhat-tracer");

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();
  let prov = ethers.getDefaultProvider();

  for (const account of accounts) {
    const balance = await prov.getBalance(account.address);
    console.log("Account: ", `${account.address} - ${balance}`);
  }
});

// task action function receives the Hardhat Runtime Environment as second argument
// https://hardhat.org/plugins/nomiclabs-hardhat-web3.html#installation
task("account-web3", "Prints accounts", async (_, { web3 }) => {
  console.log(await web3.eth.getAccounts());
});

// task action function receives the Hardhat Runtime Environment as second argument
task("blockNumber", "Prints the current block number", async (_, { ethers }) => {
  await ethers.provider.getBlockNumber().then(blockNumber => {
    console.log("Current block number: " + blockNumber);
  });
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: "0.5.16",
  etherscan: {
    apiKey: "JDXPI4CQHU3QG7PYF9FUQRJRWHW4WAXBFC",
  },
  gasReporter: {
    currency: "USD",
    // gasPrice: 21, // Default is loaded at runtime from the eth gas station api
    coinmarketcap: "3eed839e-7256-482e-89ab-7c03fa62d833",
  },
  // networks: {
  //   rinkeby: {
  //     url: "", //Infura url with projectId
  //     accounts: [""], // add the account that will deploy the contract (private key)
  //   },
  //   mainnet: {
  //     url: "", //Infura url with projectId
  //     accounts: [""], // add the account that will deploy the contract (private key)
  //   },
  // },
};
