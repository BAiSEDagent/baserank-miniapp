# Delta Audit Note — 2026-03-05

This note maps findings from the externally provided older-contract report to the current repository contract state.

## Scope
- Current contract: `contracts/src/BaseRankMarket.sol`
- Current tests: `contracts/test/BaseRankMarket.t.sol`

## Findings status mapping

### 1) Duplicate appId check in market creation
- Older report status: Missing
- Current status: **FIXED**
- Evidence: `openMarket` rejects duplicates with `DuplicateCandidate()`.

### 2) No emergency pause / circuit breaker
- Older report status: Missing
- Current status: **FIXED**
- Evidence: `pause()` / `unpause()` and `whenNotPaused` on predict/permit/claim.

### 3) No-winner locked-funds bug
- Older report status: Present
- Current status: **FIXED**
- Evidence: `isRefund` mode; users can claim original stake when `totalWinningPool == 0`.

### 4) Single-step ownership transfer
- Older report status: Present
- Current status: **FIXED**
- Evidence: `Ownable2Step` in contract inheritance.

### 5) Missing permit path
- Older report status: Missing
- Current status: **FIXED (contract-side)**
- Evidence: `predictWithPermit` function implemented.
- Remaining integration task: frontend typed-data signing + ABI wiring.

### 6) Retroactive fee manipulation concern
- Older report status: Global mutable fee risk
- Current status: **MITIGATED**
- Evidence: per-market `feeBps` stored in Market struct and used for payout/fee math.

### 7) Fee collection semantics
- Older report status: weakly specified
- Current status: **IMPROVED**
- Evidence: explicit `collectFee` + one-time guard `feeCollected`.

### 8) Dust/finalization policy
- Older report status: missing
- Current status: **PARTIALLY ADDRESSED**
- Evidence: `sweepResidual` with 30-day gate.
- Remaining recommendation: document ops policy + post-claim accounting monitoring.

### 9) Admin centralization trust model
- Older report status: High trust assumption
- Current status: **OPEN (architectural)**
- Evidence: owner/safe still resolves winners; no onchain oracle/attestation verification.

## Current blockers before replacement mainnet deployment
1. Frontend permit integration and ABI sync (still failing in integration audit).
2. Final external review sign-off of current hardened contract branch.
3. Safe operational controls documented for resolution + fee actions.

## Summary
Current repository contract is materially stronger than the older snapshot and closes multiple reported vulnerabilities. Main remaining high-level risk is centralized resolution trust model and incomplete permit integration in frontend.
