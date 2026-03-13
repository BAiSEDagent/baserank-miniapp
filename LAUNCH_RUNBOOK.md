# BaseRank Launch Runbook

## Ship Targets
- **Logic freeze:** `d24e64e`
- **Repo/operator polish:** `f78bb7a`

## Current Architecture
Canonical onchain stack:
- `contracts/src/EventRegistry.sol`
- `contracts/src/TierMarket.sol`
- `contracts/src/BatchClaimer.sol`

Canonical frontend/event-tier path:
- `src/app/page.tsx`
- `src/app/api/activity/route.ts`
- `src/app/api/positions/route.ts`
- `src/lib/event-tier.ts`
- `src/lib/candidate-id.ts`

## Trust Assumptions
- owner/admin keys remain trusted
- resolver/governance flow remains trusted operationally
- `claimFor(user)` is permissionless but non-custodial

## Pre-Launch Gates
Run from repo root unless noted.

### Contracts
```bash
cd contracts
forge test
```
Expected: `149/149 PASS`

### App
```bash
cd ..
npm run build
npm run lint
npx gitleaks detect --source . --no-git
npm audit --audit-level=high
```
Expected:
- build PASS
- lint PASS (warnings only acceptable if already reviewed)
- gitleaks PASS
- npm audit exits 0 at high threshold

## Required Production Environment
Set all event-tier env vars in Vercel before launch:

```env
NEXT_PUBLIC_EVENT_REGISTRY_ADDRESS=
NEXT_PUBLIC_BATCH_CLAIMER_ADDRESS=
NEXT_PUBLIC_APP_TOP10_MARKET_ADDRESS=
NEXT_PUBLIC_APP_TOP5_MARKET_ADDRESS=
NEXT_PUBLIC_APP_TOP1_MARKET_ADDRESS=
NEXT_PUBLIC_CHAIN_TOP10_MARKET_ADDRESS=
NEXT_PUBLIC_CHAIN_TOP5_MARKET_ADDRESS=
NEXT_PUBLIC_CHAIN_TOP1_MARKET_ADDRESS=
NEXT_PUBLIC_ACTIVE_EVENT_ID=
PAYMASTER_URL=
```

### Hard Rules
- `PAYMASTER_URL` must be set in production
- do not rely on `mainnet.base.org` in production
- all addresses must be Base mainnet addresses
- `NEXT_PUBLIC_ACTIVE_EVENT_ID` must match the active EventRegistry event

## Deploy
```bash
vercel --prod --yes
```

## Post-Deploy Verification

### 1. Pull envs back and inspect raw values
```bash
vercel env pull .env.vercel.check
cat .env.vercel.check
```
Check:
- no extra quotes
- no trailing newlines
- all event-tier addresses present
- `NEXT_PUBLIC_ACTIVE_EVENT_ID` correct

### 2. Verify API health
```bash
curl -s https://baserank-miniapp.vercel.app/api/activity
curl -s "https://baserank-miniapp.vercel.app/api/positions?address=<known-address>"
```
Check:
- activity returns event-tier market summaries, not V2 pools
- positions returns event-tier positions keyed by canonical candidate ids

### 3. Verify UI contract surface
Manual checks:
- footer shows EventRegistry + BatchClaimer addresses
- Trade opens BetSheet
- tier selection changes intended target market
- claim screen shows BatchClaimer-based claim preview

### 4. Verify chain operations manually
Use a real wallet and small stake:
- approve USDC to resolved TierMarket
- `predict(candidateId, amount)` succeeds
- position appears in Track tab
- claim preview appears after resolution when applicable

## Wednesday Ops Cadence
- lock target: Wednesday ~19:55 UTC
- open target: previous Wednesday ~20:05 UTC
- resolve target: Wednesday ~20:30 UTC

Do not drift from this cadence.

## Incident Response

### If leaderboard display is stale
- verify upstream Base leaderboard API freshness
- verify `/api/leaderboard` freshness
- do not submit onchain resolution from stale/off-by-one source data

### If production RPC missing or broken
Expected behavior:
- API routes fail closed with explicit error
- UI degrades gracefully

Action:
- fix `PAYMASTER_URL`
- redeploy
- re-check `/api/activity` and `/api/positions`

### If wrong event id is configured
Symptoms:
- empty pools
- empty positions
- writes land in unexpected markets or fail

Action:
- correct `NEXT_PUBLIC_ACTIVE_EVENT_ID`
- redeploy
- verify footer + APIs + stake flow again

### If resolution incident occurs
- stop opening new events
- publish incident note
- do not silently patch outcome handling
- use EventRegistry/TierMarket operational runbook for formal recovery

## Deferred Hardening
- third-party professional audit
- timelock on admin functions
- optional pause path on staking
- gas profiling on large candidate sets
- formal invariant verification
