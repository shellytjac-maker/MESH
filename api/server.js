const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');

// Safe fallback for deployed metadata
let deployed = {
 accountAddress: "0x1111111111111111111111111111111111111111",
 ownerAddress: "0x2222222222222222222222222222222222222222",
 usdcAddress: "0x3333333333333333333333333333333333333333"
};

try {
 const fileData = fs.readFileSync(path.join(__dirname, 'deployed.json'), 'utf8');
 deployed = { ...deployed, ...JSON.parse(fileData) };
} catch (e) {
 console.warn("Using fallback deployment addresses");
}

// In-memory agent registry & balances for live demo
const agents = new Map();
const mockBalances = new Map();

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Create a new autonomous agent
app.post('/api/agents', (req, res) => {
 try {
   const { capUsd, spendCap, expires, durationSeconds, label } = req.body;

   const fakeAddress = "0x" + Array.from({ length: 40 }, () =>
     Math.floor(Math.random() * 16).toString(16)
   ).join('');

   const parsedCap = Number(capUsd || spendCap || 100);
   const duration = Number(durationSeconds) || (Number(expires) * 60) || 3600;
   const validUntil = Math.floor(Date.now() / 1000) + duration;

   const agentData = {
     agentId: fakeAddress,
     label: label || 'Shopping Agent',
     address: fakeAddress,
     capUsd: parsedCap,
     remainingCapUsd: parsedCap,
     validUntil: validUntil,
     revoked: false,
     createdAt: Date.now()
   };

   agents.set(fakeAddress, agentData);

   return res.json({
     success: true,
     agentId: fakeAddress,
     label: agentData.label,
     address: fakeAddress,
     capUsd: parsedCap,
     remainingCapUsd: parsedCap,
     validUntil: validUntil,
     txHash: "0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join('')
   });
 } catch (err) {
   return res.status(500).json({ error: err.message });
 }
});

// List all known agents
app.get('/api/agents', (req, res) => {
 const list = Array.from(agents.values()).map((a) => ({
   agentId: a.address,
   label: a.label,
   address: a.address,
   remainingCapUsd: a.remainingCapUsd,
   revoked: a.revoked
 }));
 res.json(list);
});

// Read single agent state
app.get('/api/agents/:agentId', (req, res) => {
 const agent = agents.get(req.params.agentId);
 if (!agent) return res.status(404).json({ error: 'unknown agent' });

 res.json({
   agentId: agent.address,
   label: agent.label,
   remainingCapUsd: agent.remainingCapUsd,
   validUntil: agent.validUntil,
   revoked: agent.revoked
 });
});

// Autonomous payment execution
app.post('/api/agents/:agentId/pay', (req, res) => {
 const agent = agents.get(req.params.agentId);
 if (!agent) return res.status(404).json({ error: 'unknown agent' });
 if (agent.revoked) return res.status(400).json({ success: false, error: 'SessionKeyRevoked' });

 const now = Math.floor(Date.now() / 1000);
 if (now > agent.validUntil) return res.status(400).json({ success: false, error: 'SessionKeyExpired' });

 const { to, amountUsd } = req.body;
 const payAmount = Number(amountUsd);

 if (payAmount > agent.remainingCapUsd) {
   return res.status(400).json({ success: false, error: 'SpendCapExceeded' });
 }

 agent.remainingCapUsd -= payAmount;

 // Update mock balance for destination
 const currentBal = mockBalances.get(to) || 1000;
 mockBalances.set(to, currentBal + payAmount);

 res.json({
   success: true,
   txHash: "0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join(''),
   paidUsd: payAmount,
   to,
   remainingCapUsd: agent.remainingCapUsd
 });
});

// Instant revocation switch
app.post('/api/agents/:agentId/revoke', (req, res) => {
 const agent = agents.get(req.params.agentId);
 if (!agent) return res.status(404).json({ error: 'unknown agent' });

 agent.revoked = true;
 res.json({
   success: true,
   agentId: agent.address,
   txHash: "0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join('')
 });
});

// USDC balance check
app.get('/api/balance/:address', (req, res) => {
 const bal = mockBalances.get(req.params.address) || 500.00;
 res.json({ address: req.params.address, balanceUsd: bal });
});

// Account info route
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
});
