const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');
const ganache = require('ganache');

function loadArtifact(name) {
  const raw = JSON.parse(fs.readFileSync(path.join(__dirname, 'artifacts', `${name}.json`), 'utf8'));
  return { abi: raw.abi, bytecode: raw.bytecode.object };
}

const sessionAccountArtifact = loadArtifact('SessionAccount');
const sessionAccountAbi = sessionAccountArtifact.abi;
const sessionAccountIface = new ethers.Interface(sessionAccountAbi);

let provider;
let usdc;
let deployedState;
const agents = new Map();

function toUnits(amountUsd) {
  return BigInt(Math.round(amountUsd * 1_000_000));
}

function fromUnits(units) {
  return Number(units) / 1_000_000;
}

function errorMessage(err) {
  const data = err?.data || err?.info?.error?.data || err?.error?.data;
  if (data) {
    try {
      const parsed = sessionAccountIface.parseError(data);
      if (parsed) return parsed.name;
    } catch (_) {
      // fall through
    }
  }
  return err.shortMessage || err.reason || err.message || String(err);
}

async function getOwnerSigner() {
  return provider.getSigner(deployedState.ownerSignerIndex);
}

async function getDeployerSigner() {
  return provider.getSigner(deployedState.deployerSignerIndex);
}

// Boots a real, in-process local EVM chain (no separate process, no
// external service) and deploys the already-audited-by-us contracts onto
// it. This runs once when the server starts and gives every deployment
// (Render, a laptop, anywhere) a working chain with zero extra setup.
async function bootstrap() {
  console.log('Starting in-process local chain...');
  const ganacheProvider = ganache.provider({
    wallet: { totalAccounts: 3 },
    logging: { quiet: true }
  });
  provider = new ethers.BrowserProvider(ganacheProvider);

  const deployer = await provider.getSigner(0);
  const owner = await provider.getSigner(1);
  const deployerAddress = await deployer.getAddress();
  const ownerAddress = await owner.getAddress();
  console.log('Deployer:', deployerAddress);
  console.log('Demo "human owner" account:', ownerAddress);

  const usdcArtifact = loadArtifact('MockUSDC');
  const factoryArtifact = loadArtifact('AccountFactory');
  const paymasterArtifact = loadArtifact('USDCPaymaster');

  const usdcFactory = new ethers.ContractFactory(usdcArtifact.abi, usdcArtifact.bytecode, deployer);
  const usdcContract = await usdcFactory.deploy();
  await usdcContract.waitForDeployment();
  console.log('MockUSDC deployed at', usdcContract.target);

  const entryPoint = deployerAddress;

  const accountFactoryFactory = new ethers.ContractFactory(factoryArtifact.abi, factoryArtifact.bytecode, deployer);
  const accountFactory = await accountFactoryFactory.deploy(entryPoint);
  await accountFactory.waitForDeployment();
  console.log('AccountFactory deployed at', accountFactory.target);

  const paymasterFactory = new ethers.ContractFactory(paymasterArtifact.abi, paymasterArtifact.bytecode, deployer);
  const paymaster = await paymasterFactory.deploy(entryPoint, usdcContract.target, deployerAddress);
  await paymaster.waitForDeployment();
  console.log('USDCPaymaster deployed at', paymaster.target);

  const salt = 1n;
  const createTx = await accountFactory.createAccount(ownerAddress, salt);
  await createTx.wait();
  const accountAddress = await accountFactory['getAddress(address,uint256)'](ownerAddress, salt);
  console.log('SessionAccount created at', accountAddress);

  const mintTx = await usdcContract.mint(accountAddress, 100_000_000); // 100.00 USDC
  await mintTx.wait();
  console.log('Minted 100.00 mock USDC to', accountAddress);

  usdc = new ethers.Contract(usdcContract.target, usdcArtifact.abi, provider);

  deployedState = {
    ownerSignerIndex: 1,
    deployerSignerIndex: 0,
    ownerAddress,
    accountAddress,
    usdcAddress: usdcContract.target
  };

  console.log('Bootstrap complete.');
}

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.post('/api/agents', async (req, res) => {
  try {
    const { capUsd, durationSeconds, label } = req.body;
    if (typeof capUsd !== 'number' || capUsd <= 0) {
      return res.status(400).json({ error: 'capUsd must be a positive number' });
    }
    const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : 3600;

    const agentWallet = ethers.Wallet.createRandom().connect(provider);

    const deployerSigner = await getDeployerSigner();
    const fundTx = await deployerSigner.sendTransaction({
      to: agentWallet.address,
      value: ethers.parseEther('0.05')
    });
    await fundTx.wait();

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployedState.accountAddress, sessionAccountAbi, ownerSigner);

    const capUnits = toUnits(capUsd);
    const validUntil = Math.floor(Date.now() / 1000) + duration;

    const tx = await accountAsOwner.authorizeSessionKey(
      agentWallet.address,
      capUnits,
      validUntil,
      deployedState.usdcAddress
    );
    const receipt = await tx.wait();

    const agentId = agentWallet.address;
    agents.set(agentId, {
      label: label || agentId,
      address: agentWallet.address,
      privateKey: agentWallet.privateKey,
      nextNonce: await provider.getTransactionCount(agentWallet.address, 'pending'),
      createdAt: Date.now()
    });

    res.json({
      agentId,
      label: agents.get(agentId).label,
      address: agentWallet.address,
      capUsd,
      validUntil,
      txHash: receipt.hash
    });
  } catch (err) {
    res.status(500).json({ error: errorMessage(err) });
  }
});

app.get('/api/agents', (req, res) => {
  const list = Array.from(agents.values()).map((a) => ({
    agentId: a.address,
    label: a.label,
    address: a.address
  }));
  res.json(list);
});

app.get('/api/agents/:agentId', async (req, res) => {
  try {
    const agent = agents.get(req.params.agentId);
    if (!agent) return res.status(404).json({ error: 'unknown agent' });

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployedState.accountAddress, sessionAccountAbi, ownerSigner);
    const sk = await accountAsOwner.sessionKeys(agent.address);

    res.json({
      agentId: agent.address,
      label: agent.label,
      remainingCapUsd: fromUnits(sk.spendCap),
      validUntil: Number(sk.validUntil),
      revoked: sk.revoked
    });
  } catch (err) {
    res.status(500).json({ error: errorMessage(err) });
  }
});

app.post('/api/agents/:agentId/pay', async (req, res) => {
  try {
    const agent = agents.get(req.params.agentId);
    if (!agent) return res.status(404).json({ error: 'unknown agent' });

    const { to, amountUsd } = req.body;
    if (!ethers.isAddress(to)) return res.status(400).json({ error: 'invalid "to" address' });
    if (typeof amountUsd !== 'number' || amountUsd <= 0) {
      return res.status(400).json({ error: 'amountUsd must be a positive number' });
    }

    const agentWallet = new ethers.Wallet(agent.privateKey, provider);
    const accountAsAgent = new ethers.Contract(deployedState.accountAddress, sessionAccountAbi, agentWallet);

    const nonce = agent.nextNonce;
    const tx = await accountAsAgent.executeSessionSpend(deployedState.usdcAddress, to, toUnits(amountUsd), { nonce });
    const receipt = await tx.wait();
    agent.nextNonce = nonce + 1;

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployedState.accountAddress, sessionAccountAbi, ownerSigner);
    const sk = await accountAsOwner.sessionKeys(agent.address);

    res.json({
      success: true,
      txHash: receipt.hash,
      paidUsd: amountUsd,
      to,
      remainingCapUsd: fromUnits(sk.spendCap)
    });
  } catch (err) {
    res.status(400).json({ success: false, error: errorMessage(err) });
  }
});

app.post('/api/agents/:agentId/revoke', async (req, res) => {
  try {
    const agent = agents.get(req.params.agentId);
    if (!agent) return res.status(404).json({ error: 'unknown agent' });

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployedState.accountAddress, sessionAccountAbi, ownerSigner);

    const tx = await accountAsOwner.revokeSessionKey(agent.address);
    const receipt = await tx.wait();

    res.json({ success: true, agentId: agent.address, txHash: receipt.hash });
  } catch (err) {
    res.status(500).json({ error: errorMessage(err) });
  }
});

app.get('/api/balance/:address', async (req, res) => {
  try {
    const bal = await usdc.balanceOf(req.params.address);
    res.json({ address: req.params.address, balanceUsd: fromUnits(bal) });
  } catch (err) {
    res.status(500).json({ error: errorMessage(err) });
  }
});

app.get('/api/account', (req, res) => {
  res.json({
    accountAddress: deployedState.accountAddress,
    ownerAddress: deployedState.ownerAddress,
    usdcAddress: deployedState.usdcAddress
  });
});

app.get('/api/health', (req, res) => {
  res.json({ ok: !!deployedState });
});

const PORT = process.env.PORT || 3000;

bootstrap()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`MESH agent API listening on port ${PORT}`);
      console.log(`Main demo account: ${deployedState.accountAddress}`);
    });
  })
  .catch((err) => {
    console.error('Bootstrap failed:', err);
    process.exit(1);
  });
