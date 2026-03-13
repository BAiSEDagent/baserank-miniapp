# BaseRank Resolution Runbook — Event-Tier

## Scope
Canonical weekly resolution flow for the audited event-tier stack:
- `EventRegistry.sol`
- `TierMarket.sol`
- `BatchClaimer.sol`

Markets are isolated by:
- leaderboard kind: `app` or `chain`
- tier: `Top 10`, `Top 5`, `#1`

## Preconditions
- active event already exists in `EventRegistry`
- all 6 TierMarkets are deployed and mapped in frontend config
- current time >= event `resolveTime`
- official Base leaderboard source is available and verified
- resolver wallet is ready
- governance/challenge operator is ready

## Canonical Candidate IDs
Every ranked candidate ID must match the same canonical key derivation used in UI and tooling:

```ts
candidateId = keccak256(abi.encodePacked("<market>:<candidateKey>"))
```

Where:
- `market` = `app` or `chain`
- `candidateKey` = stable canonical identifier (not mutable display text)

Do not derive from display name unless display name is the canonical key.

## Resolution Flow

### 1. Verify source snapshot
Capture:
- source URL
- captured timestamp
- final ranked app ids / chain ids
- operator identity

### 2. Build ranked candidate arrays
Construct ranked arrays for the active event:
- `appRankedCandidateIds[]`
- `chainRankedCandidateIds[]`

Validation:
- no duplicates
- every candidate exists in EventRegistry candidate set
- candidate IDs were derived from canonical keys

### 3. Compute snapshot hash
Hash the canonical snapshot payload offchain and keep the same `snapshotHash` for all relevant resolution submissions.

### 4. Submit resolution to EventRegistry
Resolver submits ranked candidate IDs.

Required checks:
- tx succeeds
- submitted rank list matches intended canonical ranking
- `snapshotHash` matches archived payload

### 5. Wait challenge window
Do not finalize early.
Governance may challenge if data is wrong.

### 6. Finalize resolution
After challenge window ends:
- finalize EventRegistry resolution
- verify event is now resolved

### 7. Resolve all 6 TierMarkets
Resolve each isolated market:
- app/top10
- app/top5
- app/top1
- chain/top10
- chain/top5
- chain/top1

Verify for each:
- tx succeeds
- state becomes `Resolved`
- fee/netPool/winningStake/noWinner values are sensible

## Cancellation Paths

### Challenge cancellation
If governance challenges successfully:
- event becomes cancelled
- affected TierMarkets must be cancelled
- refund path opens

### Timeout cancellation
If resolution is not submitted/finalized in time:
- cancel event via timeout path
- cancel TierMarkets
- refund path opens

## Post-Resolution Validation
- known winner has non-zero `claimable`
- known loser has zero `claimable`
- no-winner tiers show refund behavior
- cancelled tiers show refund behavior
- frontend `/api/activity` reflects updated state
- frontend `/api/positions` reflects updated claimability

## Claim Flow Validation
- BatchClaimer preview path shows correct claimable markets
- BatchClaimer claim path works for a known winning or refunding account
- BatchClaimer does not retain funds

## Transparency / Ops Post
Publish:
- event id
- source URL
- captured timestamp
- snapshot hash
- resolution status
- incident notes if any

## If Something Goes Wrong
- do not silently patch outcomes
- stop opening new events if resolution integrity is in doubt
- publish incident note
- preserve snapshot payload and tx references for auditability
