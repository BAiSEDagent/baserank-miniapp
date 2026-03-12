# BaseRank Mini App

BaseRank is a Base mini app for event-tier prediction markets on weekly leaderboard outcomes.

Frozen ship target for the audited event-tier lane:
- **Branch:** `spec/event-tier`
- **Commit:** `d24e64e`

## Architecture

### Contracts
- `contracts/src/EventRegistry.sol` — event lifecycle, resolution windows, governance / resolver snapshots
- `contracts/src/TierMarket.sol` — one audited parimutuel market per `(event, marketKind, tier)`
- `contracts/src/BatchClaimer.sol` — best-effort batch claim wrapper with per-market success/failure events

### Frontend / API
- `src/app/page.tsx` — mobile-first mini app UI
- `src/app/api/activity/route.ts` — event-tier market summary read path
- `src/app/api/positions/route.ts` — user positions / claim preview read path
- `src/lib/event-tier.ts` — canonical event-tier config loader
- `src/lib/candidate-id.ts` — canonical candidate ID derivation
- `src/lib/contracts/BatchClaimerABI.ts` — receipt parsing for claim result reporting

## Event-tier model

BaseRank no longer uses the legacy single `BaseRankMarket.sol` UI path for the shipped lane.

Predictions now flow through:
1. resolve active event-tier config
2. resolve one audited `TierMarket`
3. derive canonical `candidateId` from stable `projectId`
4. approve USDC for that market
5. call `TierMarket.predict(candidateId, amount)`

Claims now flow through:
1. read claimable market state from event-tier APIs
2. submit `BatchClaimer.claimMany(markets)`
3. parse `ClaimSucceeded` / `ClaimFailed` from the receipt
4. refresh positions before reporting outcomes in the UI

## Required environment

Create `.env.local` for local development:

```bash
# Event registry / claim router
NEXT_PUBLIC_ACTIVE_EVENT_ID=
NEXT_PUBLIC_EVENT_REGISTRY_ADDRESS=
NEXT_PUBLIC_BATCH_CLAIMER_ADDRESS=

# App leaderboard markets
NEXT_PUBLIC_APP_TOP10_MARKET_ADDRESS=
NEXT_PUBLIC_APP_TOP5_MARKET_ADDRESS=
NEXT_PUBLIC_APP_TOP1_MARKET_ADDRESS=

# Chain leaderboard markets
NEXT_PUBLIC_CHAIN_TOP10_MARKET_ADDRESS=
NEXT_PUBLIC_CHAIN_TOP5_MARKET_ADDRESS=
NEXT_PUBLIC_CHAIN_TOP1_MARKET_ADDRESS=

# Server-side RPC / paymaster proxy
PAYMASTER_URL=
PAYMASTER_API_KEY=
```

## RPC behavior

Server routes use `PAYMASTER_URL` for onchain reads.

- **Production:** `PAYMASTER_URL` is required and routes fail closed if it is missing.
- **Local development:** routes may fall back to `https://mainnet.base.org` for convenience.

This is intentional so production config drift fails loudly instead of degrading into public-RPC rate limiting.

## Run app

```bash
npm install
npm run dev
```

## Validation

```bash
npm run lint
npm run build
cd contracts && forge test
```

## Audit / ship posture

Validated on the frozen event-tier ship target:
- `npm run build` → PASS
- `npm run lint` → PASS (warnings only)
- `forge test` → PASS (`149/149`)

Resolved in the final UI fix-pass:
- batch-claim outcome reporting derived from actual claim events
- selection restore keyed by canonical `projectId`
- avoidable lossy API math reduced to display-layer formatting only
- `BatchClaimerABI` aligned for receipt parsing

## Known trust assumptions

- owner/admin keys remain trusted
- resolver/governance flow remains trusted operationally
- `claimFor(user)` is permissionless but non-custodial

## Deferred hardening

- third-party professional audit
- timelock on admin functions
- optional pause path on staking
- gas profiling on large candidate sets
- formal invariant verification
