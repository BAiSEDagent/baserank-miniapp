# Current State

## Canonical Stack
- EventRegistry
- TierMarket
- BatchClaimer

## Commits to know
- `d24e64e` — logic freeze target
- `f78bb7a` — repo/operator polish target
- `620fad6` — launch runbook, deployment checklist, updated resolution runbook
- `45b548c` — anti-gaming market design memo

## UI migration commits
- `e5d5e11` — event-tier frontend foundation
- `8086f0f` — ABI alignment correction
- `457c7d2` — write-path migration to TierMarket
- `899d4c8` — read-path migration to event-tier activity/positions
- `3ce2ad7` — Results claim preview + BatchClaimer claimMany wiring

## Relevant files
- `src/lib/event-tier.ts`
- `src/lib/candidate-id.ts`
- `src/app/page.tsx`
- `src/app/api/activity/route.ts`
- `src/app/api/positions/route.ts`
- `src/lib/contracts/EventRegistryABI.ts`
- `src/lib/contracts/TierMarketABI.ts`
- `src/lib/contracts/BatchClaimerABI.ts`

## Trust assumptions
- owner/admin keys trusted
- resolver/governance flow trusted operationally
- `claimFor(user)` permissionless but non-custodial

## Forward product direction
Public analytics and Builder Codes reduce hidden-information edge.
BaseRank should strengthen around:
- better market structure
- future-interval predictions
- yes/no and head-to-head formats
- anti-gaming timing design

## Read these docs
- `docs/V3_UI_INTEGRATION_GAP_PLAN.md`
- `docs/ANTI_GAMING_MARKET_DESIGN.md`
- `LAUNCH_RUNBOOK.md`
- `DEPLOYMENT_CHECKLIST.md`
- `RUNBOOK_RESOLUTION.md`
