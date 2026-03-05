# BaseRankMarket Security Gate — 2026-03-05

## Verdict
- **GO (Limited Beta / Low TVL):** Yes
- **GO (Public Scale / High TVL):** **NO-GO** until hardening items are closed

## What was executed now
- Foundry test suite run: **5/5 passed**
- Quick dangerous-pattern grep:
  - `tx.origin`: not present
  - `delegatecall`/`selfdestruct`: not present
  - timestamp-gating present (expected for market windows)

## Current Strengths
1. `predict` and `claimWinnings` guarded by `nonReentrant`
2. `SafeERC20` used for token transfers
3. Owner-gated lifecycle functions (`openMarket`, `lockMarket`, `resolveMarket`)
4. Permit path implemented for 1-click UX (`predictWithPermit`)
5. Accounting model is deterministic and test-covered for core payout path

## Open Risks (must close before high-value scale)
1. **No emergency pause/circuit breaker**
   - Add `Pausable` and gate user entry/claim paths.
2. **No timelock / staged admin controls**
   - Lifecycle and fee controls are immediate owner actions.
3. **No fuzz/invariant test layer yet**
   - Need conservation invariants across random stake patterns.
4. **Fee transfer/collection operational model not fully explicit in tests**
   - Expand tests around fee destination and one-time collection semantics.
5. **No external independent audit report**
   - Internal tests are not a substitute for 3rd-party review.

## Required Hardening Checklist (GO for scale)
- [ ] Add `Pausable` and test pause/unpause behavior
- [ ] Add 2-step ownership transfer / timelock wrapper for admin ops
- [ ] Add invariant tests:
      - distributable + fees <= total pool
      - total claims <= distributable
      - no double-claim across resolved markets
- [ ] Add adversarial tests for malformed winner sets and boundary timestamps
- [ ] Produce signed operations runbook for Safe signers
- [ ] External audit or peer review with written report

## Operational Limits Until Hardening Complete
- Keep fee bps conservative
- Keep market TVL low and capped
- Use Safe owner only (no hot-wallet admin)
- Publish transparent market snapshot hashes on each resolve
