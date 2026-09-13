const BASE = process.env.API_BASE || 'http://localhost:3000/api';

function log(...args) {
  console.log(...args);
}

async function main() {
  log('');
  log('=====================================================');
  log(' MESH Agent API -- Live Demo');
  log('=====================================================');
  log('');

  log('Step 1: A human spins up an autonomous shopping agent with a scoped budget...');
  const createRes = await fetch(`${BASE}/agents`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ capUsd: 1.0, durationSeconds: 3600, label: 'Shopping Agent' })
  });
  const agent = await createRes.json();
  if (!agent.agentId) {
    console.error('Failed to create agent:', agent);
    process.exit(1);
  }
  log('  Agent created:', agent.label, agent.address);
  log('  Policy: up to $' + agent.capUsd + ', expires in 1 hour, USDC only.');
  log("  (The agent never touches the human's master key -- it only holds this scoped session key.)");
  log('');

  const merchant = '0x000000000000000000000000000000000000dEaD';

  log('Step 2: The agent autonomously makes three small purchases...');
  for (let i = 1; i <= 3; i++) {
    const payRes = await fetch(`${BASE}/agents/${agent.agentId}/pay`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ to: merchant, amountUsd: 0.1 })
    });
    const pay = await payRes.json();
    if (pay.success) {
      log(`  Purchase ${i}: paid $0.10. Remaining budget: $${pay.remainingCapUsd}`);
    } else {
      log(`  Purchase ${i}: FAILED --`, pay.error);
    }
  }
  log('');

  log('Step 3: The agent (or a bug, or an attacker) tries to overspend...');
  const overRes = await fetch(`${BASE}/agents/${agent.agentId}/pay`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ to: merchant, amountUsd: 5.0 })
  });
  const over = await overRes.json();
  log('  Result:', over.success ? 'SUCCEEDED (this would be a bug!)' : 'Correctly rejected -- ' + over.error);
  log('');

  log('Step 4: The human revokes the agent instantly...');
  const revokeRes = await fetch(`${BASE}/agents/${agent.agentId}/revoke`, { method: 'POST' });
  const revoke = await revokeRes.json();
  log('  Revoked in tx', revoke.txHash);

  const blockedRes = await fetch(`${BASE}/agents/${agent.agentId}/pay`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ to: merchant, amountUsd: 0.1 })
  });
  const blocked = await blockedRes.json();
  log('  Post-revoke payment attempt:', blocked.success ? 'SUCCEEDED (bug!)' : 'Correctly blocked -- ' + blocked.error);
  log('');

  log('Step 5: Checking final balances...');
  const acctRes = await fetch(`${BASE}/account`);
  const acct = await acctRes.json();
  const humanBal = await (await fetch(`${BASE}/balance/${acct.accountAddress}`)).json();
  const merchantBal = await (await fetch(`${BASE}/balance/${merchant}`)).json();
  log('  Human account balance:', '$' + humanBal.balanceUsd);
  log('  Merchant balance:     ', '$' + merchantBal.balanceUsd);
  log('');
  log('Demo complete.');
}

main().catch((err) => {
  console.error('Demo failed:', err);
  process.exit(1);
});
