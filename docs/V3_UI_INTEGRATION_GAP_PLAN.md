# BaseRank — V3 UI Integration Gap Plan

## Status
- Current repo ship commit: `f227f56`
- Current contract audit baseline: `99d3fce` carried forward unchanged into `f227f56`
- Public launch verdict: **GO**
- **No artificial TVL cap** in launch framing

## Objective
Migrate the BaseRank frontend from the current V2/live + V3-preview hybrid into a clean UI integration for the **audited event-tier architecture**:

- `EventRegistry.sol`
- `TierMarket.sol`
- `BatchClaimer.sol`

**Do not** integrate the old monolithic `BaseRankMarketV3.sol` draft.

---

## Canonical Decision

### Contract family to target
**Target:** audited event-tier stack  
**Do not target:** legacy `BaseRankMarketV3.sol`

### Product framing
- Launch as a **public product**, not a tiny capped beta
- Be explicit about trust assumptions
- Keep deferred hardening as roadmap items, not launch blockers

---

## Current Gaps

### 1. Write path still V2
Current UI writes to:
- `BaseRankMarketV2.predict(epochId, marketType, candidateId, amount)`

Missing:
- routing tier selection to the correct TierMarket
- event-tier address selection
- event-id based writes

### 2. Read path still V2-shaped
Current UI reads:
- `marketDetails(WEEK_ID, marketType)` from V2 contract

Missing:
- EventRegistry timing/state
- per-tier market states/pools
- claim deadlines / cancellation states
- snapshot hash display

### 3. Positions tab not event-tier native
Missing:
- tier-aware position model
- per-market claimability
- claimed/unclaimed state
- no-winner / cancelled refund state
- batch claim UX

### 4. Results tab still placeholder/demo
Missing:
- real resolved outcome state
- real claimable amount
- claim deadline
- refund/no-winner/cancelled explanations

### 5. Epoch/event wiring still V2 constant-based
Current UI:
- `WEEK_ID = BigInt(20260311)`

Missing:
- active `eventId`
- event → tier market mapping
- weekly rollover config

### 6. Candidate ID canonicalization not centralized
Current UI derives IDs from app name/marketType string composition.

Need one canonical shared helper across:
- frontend
- resolver scripts
- ops flow
- indexer/API

---

## Required Config Surface

Add explicit env/config for event-tier:

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
```

If we later add a factory/registry for market discovery, this can be reduced. For now, explicit addresses are safer and clearer.

---

## Frontend Integration Model

## A. Canonical market map
Create one source of truth in frontend config:

```ts
type MarketKind = 'app' | 'chain'
type TierKey = 'top10' | 'top5' | 'top1'

const MARKET_MAP: Record<MarketKind, Record<TierKey, `0x${string}`>>
```

This replaces implicit V2 `marketType` assumptions.

## B. Event model
Frontend should think in:
- `eventId`
- `marketKind` (`app` / `chain`)
- `tierKey` (`top10` / `top5` / `top1`)

Not just a single `WEEK_ID` + one market contract.

## C. Candidate ID helper
Create a shared helper:

```ts
candidateIdForProject(input: { market: 'app' | 'chain'; projectName: string }): `0x${string}`
```

Must exactly match resolver/ops hashing.

---

## File-by-File Plan

### Phase 1 — Contract config + shared types
**Files:**
- `src/lib/contracts/*` (new event-tier ABIs)
- `src/lib/event-tier.ts` (new)
- `src/lib/candidate-id.ts` (new)

**Deliverables:**
- EventRegistry ABI
- TierMarket ABI
- BatchClaimer ABI
- env parsing + address validation
- market map
- active event id
- shared candidate id helper

### Phase 2 — Market read path migration
**Files:**
- `src/app/page.tsx`
- `src/app/api/activity/route.ts`

**Deliverables:**
- replace V2 `marketDetails(WEEK_ID, marketType)` reads
- read per-tier market states and pools
- read EventRegistry timing (`getEventTiming`, `getEventMeta`, `claimDeadline` path via UI/API model)
- aggregate for hero/market cards cleanly

### Phase 3 — Write path migration
**Files:**
- `src/app/page.tsx`
- `src/components/bet-sheet.tsx`

**Deliverables:**
- map tier selection to actual TierMarket address
- approve correct spender per selected tier market
- call `predict(candidateId, amount)` on selected TierMarket
- preserve smart-wallet sequential approve → predict flow

### Phase 4 — Positions API rewrite
**Files:**
- `src/app/api/positions/route.ts`

**Deliverables:**
- query all 6 tier markets
- return unified positions model:
  - market kind
  - tier
  - candidateId
  - label/projectName
  - amount
  - claimable
  - claimed state if inferable
  - resolved/cancelled/no-winner state
- support batch claim UI

### Phase 5 — Track / Results tab real wiring
**Files:**
- `src/app/page.tsx`

**Deliverables:**
- real live positions, not preview semantics
- real results state
- real claimable totals
- claim deadline display
- cancelled/no-winner explanation banners
- snapshot hash / canonical resolution copy

### Phase 6 — Batch claim UX
**Files:**
- `src/app/page.tsx`
- possibly `src/components/` new claim CTA component

**Deliverables:**
- `previewMany()` integration
- `claimMany()` integration
- per-market success/failure user feedback
- fallback single-claim path if needed

### Phase 7 — Ops + runbook alignment
**Files:**
- `src/app/ops/checklist/page.tsx`
- `RUNBOOK_RESOLUTION.md`
- docs as needed

**Deliverables:**
- event-tier aware ops checklist
- active event rollover process
- Wednesday resolution runbook aligned to EventRegistry/TierMarket flow

---

## Acceptance Criteria

### Functional
- User can select `Top 10` / `Top 5` / `#1`
- UI submits to the correct audited TierMarket
- Positions tab shows real tier-aware bets
- Results tab shows real claimable state
- Claim flow works through BatchClaimer
- UI distinguishes:
  - live leaderboard
  - canonical onchain resolved snapshot

### Product
- No fake fixed-odds copy if payouts are pari-mutuel
- Pool numbers reflect actual isolated pools / aggregate intentionally
- No V2/V3 hybrid confusion in user copy

### Technical
- Build passes
- Lint passes
- Gitleaks passes
- Audit threshold passes
- No stale V2-only code on critical user path

---

## Risks / Things to Avoid

1. **Do not patch old monolithic V3 draft into the UI**
2. **Do not keep mixed V2 read path + event-tier write path**
3. **Do not use decorative payout multipliers that imply fixed odds**
4. **Do not let candidate hashing drift between frontend and resolver**
5. **Do not hide challenge/cancel/no-winner states**

---

## Recommended Implementation Order

### Unit 1
Contract config + shared types + candidate ID helper

### Unit 2
Write path migration (bet sheet → tier market)

### Unit 3
Positions API rewrite

### Unit 4
Results/claim wiring

### Unit 5
Ops/runbook cleanup

---

## Launch Framing

Use this language going forward:
- **Public launch: GO**
- Trust assumptions are documented
- Deferred hardening remains:
  - third-party audit
  - timelock
  - optional pause path
  - gas profiling on large candidate sets
  - formal invariants

**Do not** reintroduce arbitrary TVL-cap language unless explicitly decided for operational reasons.
