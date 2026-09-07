# MESH·OP — ETHOnline 2026 build plan

Event window: **Sept 4 – Sept 16, 2026**. Submission deadline: **Sun Sept 13, 12:00pm EDT**.
Track: **Start Fresh (Classic)** — all code in this repo is written during the event window.

Target prizes (see conversation for full qualification text):

1. Hedera — *AI & Agentic Payments on Hedera* ($6,000 pool, up to 3×$2,000)
2. Chainlink — *Best Confidential Workflow* ($2,000 pool, up to 2×$1,000)
3. Arc (Circle) — *Best Agentic Economy Application with Circle Agent Stack* ($1,667)

## Day-by-day

**Day 1–2 — Wire the core loop (mocked rails)**
- [x] Typed schema: `PaymentRequirement`, `PaymentProof`, `ConfidentialRoutingInput/Decision` (`src/types.ts`)
- [x] x402 gate middleware: 402 challenge → verify proof → serve (`src/service/x402.ts`)
- [x] Two priced endpoints: `/inference/mesh-mini`, `/data/usage-feed` (`src/service/index.ts`)
- [x] Confidential router stub with real decision logic, mock enclave boundary (`src/confidential/router.ts`)
- [x] Rail stubs for Hedera + Arc behind one interface, `MOCK_RAILS` toggle (`src/rails/*.ts`)
- [x] Agent client: discover → route → pay → retry (`src/agent/index.ts`)
- [x] End-to-end demo script, 3 scenarios (`scripts/demo.ts`)

**Day 3–4 — Go live on Hedera (primary target, best fit)**
- [ ] Create Hedera testnet operator account, fund via faucet
- [ ] Stand up Blocky402 facilitator config for the service's payee account
- [ ] Swap `payHedera`/`verifyHederaPayment` mock bodies for the `@hashgraph/sdk` live path already sketched in `src/rails/hedera.ts`
- [ ] Re-run `scripts/demo.ts` with `MOCK_RAILS=false` for the Hedera-only path
- [ ] Record demo video (≤5 min) showing a real paid request settle on testnet
- [ ] Write up qualification checklist answers in submission form (x402-gated service ✅, consuming platform/agent ✅, public repo ✅, demo video)

**Day 5 — Go live on Chainlink CRE**
- [ ] Scaffold a CRE workflow project from `docs.chain.link/cre-templates/hello-confidential-workflows`
- [ ] Port `decideRoute()` body verbatim into a `cre.HandlerInTee(...)` handler
- [ ] Simulate via CRE CLI; capture logs/output as submission evidence
- [ ] Confirm the confidential input (budget, maxPerCallUsd, preferredRail) never appears outside the handler

**Day 6 — Go live on Arc (stretch)**
- [ ] Circle Agent Stack sandbox account + two wallets (buyer agent, seller/service)
- [ ] Swap `payArc`/`verifyArcPayment` mocks for the Circle Agent Stack live path sketched in `src/rails/arc.ts`
- [ ] Re-run Agent B scenario against Arc testnet USDC
- [ ] Architecture diagram for submission (Arc track requires one)

**Day 7 — Submission polish**
- [ ] Three demo videos (or one combined video with three chapters)
- [ ] Fill FEEDBACK.md-style notes only if pursuing Uniswap track too (not currently in scope)
- [ ] Double-check each track's specific "qualification requirements" checklist against the actual repo state
- [ ] Submit before Sept 13, 12:00pm EDT — do not wait for the 16th

## Known open questions carried over from the project plan

These still apply and should be resolved by end of Day 2, since they affect which rail becomes "default" in the router:

- **B2B vs B2C vs A2A** — this demo assumes A2A/agent-to-service; human-facing tipping UX is out of scope for the hackathon build.
- **Which chain leads** — the router currently defaults sub-$0.005 calls to Hedera and larger/shielded calls to Arc; revisit after real testnet latency numbers come in from Day 3.
- **Privacy model** — currently "selective disclosure" (only the routing decision leaves the enclave); fully shielded amounts/parties on-chain is out of scope for this build.

## Risks (carried from project plan, hackathon-scoped)

| Risk | Hackathon mitigation |
|---|---|
| ZK/TEE latency | Sidestepped for the hackathon: CRE Confidential Workflow (TEE) instead of ZK-SNARKs, per the Chainlink track's actual mechanism. |
| Liquidity for settlement | Testnet only; no real liquidity risk during the event. |
| Two chains, one demo window | Rail interface (`src/rails/*.ts`) is written so either rail can go live independently — the demo degrades gracefully to "2 of 3 live" if time runs out. |
