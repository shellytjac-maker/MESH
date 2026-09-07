# MESH·OP

**Privacy-native decentralized micropayments with autonomous orchestration.**
ETHOnline 2026 — Start Fresh (Classic) track.

MESH·OP is one protocol for three converging problems: payments too coarse for
sub-cent value, privacy bolted onto payment metadata as an afterthought, and
AI agent pipelines that can't pay for compute or data without a human in the
loop. This repo is a working, runnable demo of the core loop: an agent
discovers a pay-per-call service, a **confidential router** decides how to
pay without ever revealing the agent's budget or preference, and settlement
happens on whichever rail that decision picks.

```
Agent  ──1. GET /resource──────────▶  x402 Service
Agent  ◀──2. 402 + price challenge──  x402 Service
Agent  ──3. private inputs──────────▶  Confidential Router (Chainlink CRE, TEE)
Agent  ◀──4. rail decision only─────  Confidential Router
Agent  ──5. settle on chosen rail───▶  Hedera (x402/HBAR) or Arc (USDC)
Agent  ──6. retry + proof───────────▶  x402 Service
Agent  ◀──7. resource───────────────  x402 Service
```

## Why three sponsor tracks

| Piece | Track | What it demonstrates |
|---|---|---|
| `src/rails/hedera.ts`, `src/service/*` | **Hedera — AI & Agentic Payments** | A live x402-gated service (`/inference/mesh-mini`, `/data/usage-feed`) with an agent that discovers, pays per call, and gets served — no API key, no subscription. |
| `src/agent/*`, `src/rails/arc.ts` | **Arc — Best Agentic Economy Application (Circle Agent Stack)** | An agent with clear, auditable decision logic that settles autonomously in USDC when the router picks Arc, using the same request/response loop as the Hedera path. |
| `src/confidential/router.ts` | **Chainlink — Best Confidential Workflow (CRE)** | Budget, per-call ceiling, and rail preference are processed inside a simulated TEE handler (`decideRoute`, written as a 1:1 drop-in for `cre.HandlerInTee`). Only the routing decision and an attestation hash leave the enclave — never the private inputs. |

Each rail file documents the exact live SDK calls (`@hashgraph/sdk` +
Blocky402 facilitator; Circle Agent Stack; `@chainlink/cre-sdk`) it stands in
for, so swapping `MOCK_RAILS=false` and filling in credentials is the only
step between this demo and a live testnet submission.

## Run it

```bash
npm install
cp .env.example .env
npm run demo
```

This starts the x402 service and runs three agents against it:

1. **Agent A** — a sub-cent data-feed call → confidential router picks **Hedera**.
2. **Agent B** — a pricier inference call with an explicit Arc preference → router picks **Arc/USDC**, honoring the agent's private preference.
3. **Agent C** — over its remaining budget → router **declines before any funds move**, and the service never sees why.

Run the service alone with `npm run service` and hit it directly:

```bash
curl -i http://localhost:4021/inference/mesh-mini
# → 402 Payment Required, with a PaymentRequirement JSON body
```

## What's mocked vs. real

- **Real:** the x402 challenge/verify protocol, the confidential-routing
  decision logic and enclave-boundary pattern, the agent's discover → route →
  pay → retry loop, and the HTTP service itself.
- **Mocked (behind `MOCK_RAILS=true`):** actual on-chain settlement and TEE
  attestation, so the demo runs without funded testnet accounts or CRE
  workflow credentials. Each rail file (`src/rails/hedera.ts`,
  `src/rails/arc.ts`) contains the exact live call it replaces.

## Roadmap beyond this hackathon

See the attached project plan (`MESHI_ProjectPlan.pdf`) for the four-phase
plan: validate & architect (Q3–Q4 2026) → build core SDK (Q1–Q2 2027) →
go-to-market (Q3–Q4 2027) → scale & standardize (2028+).
