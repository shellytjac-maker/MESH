const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

const RPC_URL = process.env.RPC_URL || 'http://127.0.0.1:8545';
const OUT_DIR = path.join(__dirname, '..', 'out');

function loadArtifact(sourceFile, contractName) {
  const p = path.join(OUT_DIR, `${sourceFile}.sol`, `${contractName}.json`);
  const raw = JSON.parse(fs.readFileSync(p, 'utf8'));
  return { abi: raw.abi, bytecode: raw.bytecode.object };
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  // Anvil starts with 10 pre-funded, unlocked test accounts and signs for
  // them itself -- so we never handle a raw private key for these two.
  const deployer = await provider.getSigner(0);
  const owner = await provider.getSigner(1);

  const deployerAddress = await deployer.getAddress();
  const ownerAddress = await owner.getAddress();

  console.log('Deploying from', deployerAddress);
  console.log('Demo "human owner" account:', ownerAddress);

  const usdcArtifact = loadArtifact('MockUSDC', 'MockUSDC');
  const factoryArtifact = loadArtifact('AccountFactory', 'AccountFactory');
  const sessionAccountArtifact = loadArtifact('SessionAccount', 'SessionAccount');
  const paymasterArtifact = loadArtifact('USDCPaymaster', 'USDCPaymaster');

  const usdcFactory = new ethers.ContractFactory(usdcArtifact.abi, usdcArtifact.bytecode, deployer);
  const usdc = await usdcFactory.deploy();
  await usdc.waitForDeployment();
  console.log('MockUSDC deployed at', usdc.target);

  // Placeholder EntryPoint address. This demo's API calls
  // executeSessionSpend directly (agent EOA as msg.sender) rather than
  // going through a real ERC-4337 bundler, so this address is never
  // actually invoked -- it just satisfies the constructor.
  const entryPoint = deployerAddress;

  const factoryFactory = new ethers.ContractFactory(factoryArtifact.abi, factoryArtifact.bytecode, deployer);
  const accountFactory = await factoryFactory.deploy(entryPoint);
  await accountFactory.waitForDeployment();
  console.log('AccountFactory deployed at', accountFactory.target);

  const sponsorSigner = deployerAddress; // placeholder for demo
  const paymasterFactory = new ethers.ContractFactory(paymasterArtifact.abi, paymasterArtifact.bytecode, deployer);
  const paymaster = await paymasterFactory.deploy(entryPoint, usdc.target, sponsorSigner);
  await paymaster.waitForDeployment();
  console.log('USDCPaymaster deployed at', paymaster.target);

  const salt = 1n;
  const createTx = await accountFactory.createAccount(ownerAddress, salt);
  await createTx.wait();
  const accountAddress = await accountFactory['getAddress(address,uint256)'](ownerAddress, salt);
  console.log('SessionAccount created at', accountAddress, 'owned by', ownerAddress);

  const mintTx = await usdc.mint(accountAddress, 100_000_000); // 100.00 USDC (6 decimals)
  await mintTx.wait();
  console.log('Minted 100.00 mock USDC to', accountAddress);

  const deployed = {
    rpcUrl: RPC_URL,
    ownerSignerIndex: 1,
    deployerSignerIndex: 0,
    ownerAddress,
    accountAddress,
    usdcAddress: usdc.target,
    factoryAddress: accountFactory.target,
    paymasterAddress: paymaster.target,
    entryPoint,
    abis: {
      sessionAccount: sessionAccountArtifact.abi,
      mockUsdc: usdcArtifact.abi
    }
  };

  fs.writeFileSync(path.join(__dirname, 'deployed.json'), JSON.stringify(deployed, null, 2));
  console.log('');
  console.log('Wrote api/deployed.json -- you can now run: npm start');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
