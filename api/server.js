const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');

const deployed = JSON.parse(fs.readFileSync(path.join(__dirname, 'deployed.json'), 'utf8'));

const rpcUrl = process.env.RPC_URL || deployed.rpcUrl || "https://ethereum-sepolia-rpc.publicnode.com";
const provider = new ethers.JsonRpcProvider(rpcUrl);
const sessionAccountAbi = deployed.abis.sessionAccount;
const mockUsdcAbi = deployed.abis.mockUsdc;
const sessionAccountIface = new ethers.Interface(sessionAccountAbi);

const usdc = new ethers.Contract(deployed.usdcAddress, mockUsdcAbi, provider);

// In-memory agent registry
// Each "agent" is its own EOA keypair acting as a SessionAccount session key.
const agents = new Map();

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function toUnits(amountUsd) {
  // MockUSDC uses 6 decimals.
  return BigInt(Math.round(amountUsd * 1_000_000));
}

function fromUnits(units) {
  return Number(units) / 1_000_000;
}

async function getOwnerSigner() {
  return provider.getSigner(deployed.ownerSignerIndex);
}

async function getDeployerSigner() {
  return provider.getSigner(deployed.deployerSignerIndex);
}

// Tries to turn a revert into the actual Solidity custom error name
// (e.g. "SpendCapExceeded") instead of ethers' generic "unknown custom error".
function errorMessage(err) {
  const data = err?.data || err?.info?.error?.data || err?.error?.data;
  if (data) {
    try {
      const parsed = sessionAccountIface.parseError(data);
      if (parsed) return parsed.name;
    } catch (_) {
      // fall through to generic message
    }
  }
  return err.shortMessage || err.reason || err.message || String(err);
}

// Create a new autonomous agent with a scoped, revocable spending policy.
app.post('/api/agents', async (req, res) => {
  try {
    const { capUsd, durationSeconds, label } = req.body;
    if (typeof capUsd !== 'number' || capUsd <= 0) {
      return res.status(400).json({ error: 'capUsd must be a positive number' });
    }
    const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : 3600;

    const agentWallet = ethers.Wallet.createRandom().connect(provider);

    // Fund the new agent with a little native gas so it can submit its own
    // transactions. (On real Arc this step disappears entirely -- gas is
    // paid in USDC via the paymaster, no separate gas token to hold.)
    const deployerSigner = await getDeployerSigner();
    const fundTx = await deployerSigner.sendTransaction({
      to: agentWallet.address,
      value: ethers.parseEther('0.05')
    });
    await fundTx.wait();

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployed.accountAddress, sessionAccountAbi, ownerSigner);

    const capUnits = toUnits(capUsd);
    const validUntil = Math.floor(Date.now() / 1000) + duration;

    const tx = await accountAsOwner.authorizeSessionKey(
      agentWallet.address,
      capUnits,
      validUntil,
      deployed.usdcAddress
    );
    const receipt = await tx.wait();

    const agentId = agentWallet.address;
    agents.set(agentId, {
      label: label || agentId,
      address: agentWallet.address,
      privateKey: agentWallet.privateKey,
      // We track the next nonce ourselves instead of relying on the
      // provider to infer it fresh each call -- avoids a race where a
      // just-mined transaction hasn't updated the node's reported count yet.
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

// List all known agents (demo convenience).
app.get('/api/agents', (req, res) => {
  const list = Array.from(agents.values()).map((a) => ({
    agentId: a.address,
    label: a.label,
    address: a.address
  }));
  res.json(list);
});

// Read an agent's live on-chain policy state.
app.get('/api/agents/:agentId', async (req, res) => {
  try {
    const agent = agents.get(req.params.agentId);
    if (!agent) return res.status(404).json({ error: 'unknown agent' });

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployed.accountAddress, sessionAccountAbi, ownerSigner);
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

// The agent autonomously makes a payment, within its on-chain-enforced policy.
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
    const accountAsAgent = new ethers.Contract(deployed.accountAddress, sessionAccountAbi, agentWallet);

    // Use our own tracked nonce rather than letting ethers re-derive it --
    // this is what actually fixes back-to-back payments from the same
    // agent colliding on the same nonce.
    const nonce = agent.nextNonce;
    const tx = await accountAsAgent.executeSessionSpend(deployed.usdcAddress, to, toUnits(amountUsd), { nonce });
    const receipt = await tx.wait();
    agent.nextNonce = nonce + 1;

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployed.accountAddress, sessionAccountAbi, ownerSigner);
    const sk = await accountAsOwner.sessionKeys(agent.address);

    res.json({
      success: true,
      txHash: receipt.hash,
      paidUsd: amountUsd,
      to,
      remainingCapUsd: fromUnits(sk.spendCap)
    });
  } catch (err) {
    // Custom Solidity errors (SpendCapExceeded, SessionKeyExpired, etc.)
    // surface here, decoded to their real name where possible.
    res.status(400).json({ success: false, error: errorMessage(err) });
  }
});

// Human-in-the-loop kill switch: revoke an agent's ability to spend, instantly.
app.post('/api/agents/:agentId/revoke', async (req, res) => {
  try {
    const agent = agents.get(req.params.agentId);
    if (!agent) return res.status(404).json({ error: 'unknown agent' });

    const ownerSigner = await getOwnerSigner();
    const accountAsOwner = new ethers.Contract(deployed.accountAddress, sessionAccountAbi, ownerSigner);

    const tx = await accountAsOwner.revokeSessionKey(agent.address);
    const receipt = await tx.wait();

    res.json({ success: true, agentId: agent.address, txHash: receipt.hash });
  } catch (err) {
    res.status(500).json({ error: errorMessage(err) });
  }
});

// Convenience: check any address's USDC balance.
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
    accountAddress: deployed.accountAddress,
    ownerAddress: deployed.ownerAddress,
    usdcAddress: deployed.usdcAddress
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`MESH agent API listening on http://localhost:${PORT}`);
  console.log(`Main demo account: ${deployed.accountAddress}`);
});
