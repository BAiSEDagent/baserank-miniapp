# BaseRank Event + Tier Market Spec (“Iron” Architecture)

## 1. Overview
- BaseRank runs weekly prediction markets on **Base L2** with **USDC (6 decimals)** as the staking/settlement token.
- Each week is represented by an **EventRegistry** entry. Every event hosts three **TierMarkets** (Top 10, Top 5, #1) that are fully isolated pools.
- Users stake on candidate apps inside each tier market. Winners are determined by the canonical Base leaderboard snapshot supplied to the EventRegistry.
- A dedicated **BatchClaimer** contract offers UX aggregation but holds no funds.
- The spec follows ethskills invariants: isolated pools, deterministic resolution with dispute windows, strict lifecycle (including CANCELLED), explicit refund/no-winner rules, and auditable accounting.

## 2. Token & Chain Assumptions
- Chain: Base Mainnet (EVM). Contracts are non-upgradeable and deployed once per product version.
- Stake token: canonical USDC (0x8335…913). Interactions use EIP‑3009 permits or pre-approved allowances.
- No ETH is accepted; all staking and payouts happen in USDC transfers.

## 3. Tier Semantics
| Tier | Question | Winners per market |
|------|----------|--------------------|
| Top 10 | “Which apps will finish Top 10 for week _W_?” | Up to 10 winners (rank 1‑10) |
| Top 5  | “Which apps will finish Top 5 for week _W_?”  | Up to 5 winners (rank 1‑5) |
| #1     | “Which app will finish #1 for week _W_?”        | Exactly 1 winner (rank == 1) |
- All other ranked apps lose in that tier. Unranked apps (rank = 0) are always losers.

## 4. Lifecycle & State Machine
Each TierMarket progresses through five states:
1. **CREATED**: Market deployed with immutable config.
2. **OPEN**: `predict()` enabled. Starts immediately at creation.
3. **LOCKED**: `predict()` disabled (must be triggered once `block.timestamp >= lockTime`).
4. **RESOLVE_SUBMITTED**: EventRegistry has received ranks; challenge window is active, claims NOT allowed.
5. **RESOLVED**: Challenge window passed (or resolved without challenge); claims open until `claimDeadline`.
6. **CANCELLED**: Terminal state if the event is aborted/timeout; full refunds available.

Rules:
- `predict()` only in OPEN. Min stake per call = 1 USDC; max stake per user per candidate configurable to mitigate whales.
- `lock()` transitions OPEN→LOCKED; permissionless once `block.timestamp >= lockTime`.
- `submitResolution()` on EventRegistry flips markets to RESOLVE_SUBMITTED and starts `challengePeriod` (minimum 24h).
- After `challengePeriod`, anyone calls `finalizeResolution()` which moves TierMarkets to RESOLVED and records winner sets.
- If resolution is not finalized within `resolutionTimeout`, anyone may trigger `cancelEvent()` which pushes every TierMarket to CANCELLED with refunds.

## 5. Resolution & Dispute Flow
1. Resolver multisig submits `rankedCandidateIds` + `snapshotHash`.
2. EventRegistry stores ranks (`finalRank[candidate]`), `resolutionHash`, `resolvedAt`, `resolver`. Resolver addresses are added to a denylist for staking (enforced in `predict`).
3. `challengePeriod` (>= 24h) begins. During this period, governance can veto by calling `challengeResolution(eventId, reason)` which cancels the event.
4. After `challengePeriod` without veto, anyone calls `finalizeResolution(eventId)` → snapshots winners in each TierMarket, sets `claimsOpenAt`, and enables claiming.
5. Claims remain open until `claimDeadline = claimsOpenAt + claimWindow` (minimum 30 days).

## 6. Candidate Ownership & Registry
- EventRegistry owns the canonical candidate list (`bytes32 candidateId = keccak256(appSlug)`), their metadata pointer, and per-event rank data.
- TierMarkets store a compact array of `candidateId`s at deployment for gas efficiency but treat EventRegistry as the source of truth for rank lookups.
- Candidate list is immutable after event creation. Any attempt to reference an unknown candidate reverts.

## 7. Access Control
| Action | Who | Notes |
| --- | --- | --- |
| `createEvent` | owner/factory | once per week |
| `createMarkets` | owner/factory | mints Top10/Top5/#1 markets |
| `predict` | anyone except resolver addresses | subject to minStake & optional maxStake |
| `lock` | owner or permissionless ≥ `lockTime` | prevents last-second forgetfulness |
| `submitResolution` | resolver multisig | writes ranks & starts challenge window |
| `challengeResolution` | governance role | cancels event (moves markets to CANCELLED) |
| `finalizeResolution` | permissionless after challenge window | snapshots winners and opens claims |
| `cancelEvent` (timeout) | permissionless after `resolutionTimeout` | pushes all markets to CANCELLED, refunds |
| `claim`/`claimMany` | user (msg.sender) | reentrancy-protected |
| `finalizeMarket` | owner after `claimDeadline` | one-shot sweep of fee + forfeited funds |

## 8. Anti-Sniping & Stake Constraints
- `snipeBuffer` (e.g., final 10 minutes before lock) enforces either:
  - cap on new stake per candidate, or
  - commit-reveal (future work). For MVP we enforce a per-user `maxStake` and log all late stakes for review.
- Min stake per call = 1 USDC to reduce dust. Max per user per candidate is configurable (default 1,000 USDC) to deter single-whale domination.

## 9. No-Winner Policy
- If `winningStake == 0`, feeAmount is forced to 0 and every staker receives a refund equal to their stake.
- Refunds must be claimed before `claimDeadline`; otherwise they are forfeited in `finalizeMarket`.

## 10. Accounting Invariants
Per TierMarket:
```
totalStaked = feeAmount + totalClaimed + refundableUnclaimed + residualDust
netPool     = totalStaked - feeAmount
```
- `feeAmount = totalStaked * feeBps / 10_000`, computed once at finalizeResolution (zeroed in no-winner case).
- Claims pay out of `netPool`. Refunds (no-winner or cancellations) pay out of `totalStaked`.
- `residualDust` arises only from integer division; no fixed wei bound but must be reported on `MarketFinalized`.

## 11. Claim Window & Finalization
- `claimsOpenAt = finalizedResolutionTime`
- `claimDeadline = claimsOpenAt + claimWindow` (claimWindow ≥ 30 days)
- `claim()` and `claimMany()` revert if `block.timestamp > claimDeadline` or `finalized == true`.
- After deadline, owner calls `finalizeMarket()` once:
  - checks RESOLVED, `block.timestamp > claimDeadline`, `finalized == false`
  - sets `finalized = true`
  - transfers `feeAmount + residualBalance` to `feeRecipient`
  - emits `MarketFinalized(market, remaining)`

## 12. Claim Model & Batch Helper
- `claim()` adheres to checks-effects-interactions and uses ReentrancyGuard.
- `claimMany(markets[])` iterates claims for `msg.sender`. To avoid griefing, it’s **best-effort**: the helper emits per-market success/failure events and continues even if one market reverts (skipping that market). Users can retry failing markets individually.
- `claimable(user)` returns the amount + breakdown per candidate for UI/subgraph.

## 13. Emergency Timeout & Cancellation
- `resolutionTimeout` (e.g., 72h after lock) ensures events can’t be stuck. If no finalization occurs before timeout, anyone may call `cancelEvent(eventId)` → all TierMarkets move to CANCELLED and allow refunds.
- A CANCELLED market refunds stakes without fee. Claims remain open until `claimDeadline` after cancellation.

## 14. Security Requirements
- All external-value functions (`predict`, `claim`, `finalizeMarket`) follow CEI and/or use ReentrancyGuard.
- Resolver addresses are stored on-chain; they are denied access to `predict()` to prevent insider trades.
- Challenge period provides a manual veto path.
- No contract can pull in funds from another market or event.

## 15. Frontend / API Data Model
(unchanged from previous spec; list event summaries, market details, user positions, etc.)

## 16. Contract Interfaces
```
EventRegistry:
  createEvent(EventConfig cfg)
  submitResolution(eventId, bytes32[] ranked, bytes32 snapshotHash)
  challengeResolution(eventId, string reason)
  finalizeResolution(eventId)
  cancelEvent(eventId)
  finalRank(eventId, candidateId) -> uint16
  isResolved(eventId) -> bool

TierMarket:
  predict(bytes32 candidateId, uint256 amount)
  lock()
  resolve()  // pulls ranks + snapshots winner set; callable after registry finalize
  claim()
  claimable(address user) -> ClaimInfo
  finalizeMarket()
  cancelMarket()  // called when event is cancelled; enables refunds

BatchClaimer:
  claimMany(address[] markets)
```

## 17. Worked Examples
(Include normal winner/loser, no-winner refund, everyone-wins soft payout, partial claim progression.)

## 18. Upgradeability & Deployment
- Contracts are non-upgradeable; new versions require deploying fresh instances and migrating state off-chain.
- For v2 features (order books, YES/NO markets, signed resolution adapters) we’ll deploy new contracts rather than mutate this version.
