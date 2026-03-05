# Findings — Integration Layer & Permit Path Audit

Date: 2026-03-05
Scope: frontend permit flow + contract edge-case behavior + ABI sync

## Summary
- Overall status for requested integration checks: **FAIL** (permit integration incomplete)

## Phase 1: stakeWithPermit Integration (Frontend)
1. Signature construction via `useSignTypedData`
- Status: **FAIL**
- Detail: No EIP-712 signing flow is present in current frontend transaction path.

2. Domain separator correctness (USDC Base domain)
- Status: **FAIL**
- Detail: Domain values are not constructed in code because permit signing is not wired.

3. Deadline handling (`now + 3600`)
- Status: **FAIL**
- Detail: No permit deadline generated because no permit path in frontend.

## Phase 2: Contract Edge Cases & Griefing
1. Refund reentrancy / CEI
- Status: **PASS**
- Detail: Claim marks user as claimed before transfer and function is `nonReentrant`.

2. Dust/spam griefing (tiny stake spam)
- Status: **FAIL**
- Detail: No explicit minimum stake floor beyond amount > 0.

3. Permit frontrunning behavior
- Status: **FAIL**
- Detail: If permit nonce is consumed first, tx can revert. No robust frontend retry path currently wired for permit path.

## Phase 3: ABI sync
1. Frontend ABI includes permit function
- Status: **FAIL**
- Detail: Current frontend ABI includes `stake` only; no `predictWithPermit` (or stake-with-permit equivalent).

## Recommended next PR scope
- Add typed-data signing and permit path wiring.
- Add market-aware permit fallback strategy (permit failure -> approve+stake path).
- Add minimum stake floor enforcement (UI + contract).
- Export and consume updated ABI in frontend.
