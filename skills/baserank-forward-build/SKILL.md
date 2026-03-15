---
name: baserank-forward-build
description: Build the next BaseRank product surface safely from the audited event-tier stack. Use when extending BaseRank after ship freeze, especially for new market formats, frontend/product iteration, Replit-agent implementation, or scoped follow-on work that must avoid legacy V2/monolithic-V3 drift.
---

# BaseRank Forward Build

You are working in the BaseRank repo after the audited ship state.

## First rule
Do **not** improvise contract architecture.

Canonical onchain stack:
- `contracts/src/EventRegistry.sol`
- `contracts/src/TierMarket.sol`
- `contracts/src/BatchClaimer.sol`

Do **not** wire new work to legacy `BaseRankMarketV3.sol`.
Do **not** reopen V2 write paths.

## Read these before changing anything
1. `README.md`
2. `docs/V3_UI_INTEGRATION_GAP_PLAN.md`
3. `docs/ANTI_GAMING_MARKET_DESIGN.md`
4. `LAUNCH_RUNBOOK.md`
5. `DEPLOYMENT_CHECKLIST.md`
6. `RUNBOOK_RESOLUTION.md`
7. `skills/baserank-forward-build/references/current-state.md`

## Current frozen state
- Logic freeze target: `d24e64e`
- Repo/operator polish: `f78bb7a`
- Launch/runbook docs: `620fad6`
- Anti-gaming memo: `45b548c`
- Event-tier UI migration units already landed after freeze; respect their architecture and only extend intentionally.

## Hard invariants
1. Candidate IDs must use the canonical helper in `src/lib/candidate-id.ts`
2. Event-tier config must come from `src/lib/event-tier.ts`
3. No fallback to V2 or legacy monolithic V3 when event-tier mode is active
4. Fail closed on missing config / unresolved market mapping
5. Public launch framing uses explicit trust assumptions, not fake trustlessness or arbitrary TVL-cap language

## Product direction
BaseRank should evolve toward stronger market design, not hidden-data dependency.

Use public data as signal, but design markets so users cannot wait until outcome is effectively known before lock.

Safer directions:
- yes/no markets
- head-to-head markets
- threshold markets
- future-interval / momentum markets

Avoid naive current-state markets if public analytics make the outcome legible before lock.

## Preferred workflow for follow-on builds
1. Define one narrow unit
2. Name exact files touched
3. State acceptance criteria up front
4. Ship one artifact-backed commit
5. Keep the event-tier integration consistent across reads, writes, positions, results, and claims

## If building UI/product features
Assume the user cares about:
- premium consumer feel
- not a crypto dashboard
- simple readable receipts
- clear trust assumptions
- correct onchain alignment beneath polished UX

## Expected outputs
When you finish a unit, return:
- commit hash
- files changed
- build/lint/test results
- raw links for audit

## Do not do these
- do not reintroduce `BaseRankMarketV3.sol` as canonical target
- do not derive candidate IDs from mutable display names
- do not ship market formats that are trivially gameable from public pre-lock data
- do not silently change trust assumptions
