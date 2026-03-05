# BaseRank Weekly Resolution Runbook (v1)

## Scope
Trusted-admin weekly settlement for BaseRank markets:
- Top10
- Top5
- Top1

Market key: `(weekId, tier)`

---

## A) Preconditions

- Market state is `Open`
- Current time >= `resolveTime`
- Official leaderboard source URL is available
- Resolver wallet (owner/multisig flow) is ready

---

## B) Build Winner Sets

From the official leaderboard snapshot, construct:

- `top10AppIds[]` (1-10 winners)
- `top5AppIds[]` (1-5 winners)
- `top1AppIds[]` (exactly 1 winner)

Validation rules:

- no duplicates in any set
- every winner appId exists in that week's candidate list
- top1 app appears in top5 and top10

---

## C) Compute Snapshot Hash

Create deterministic payload:

```json
{
  "weekId": 12,
  "sourceUrl": "https://www.base.dev/apps/.../leaderboard",
  "capturedAt": "2026-03-10T16:00:00Z",
  "top10": ["..."],
  "top5": ["..."],
  "top1": ["..."]
}
```

Compute keccak256 of this canonical payload.
Use that value as `snapshotHash` in all 3 resolve txs.

---

## D) Resolve Tx Order (strict)

1. Resolve Top10
2. Resolve Top5
3. Resolve Top1

Contract call:

```solidity
resolveMarket(weekId, tier, winners[], snapshotHash)
```

After each tx, verify:
- tx succeeded
- `MarketResolved` event emitted
- `winnerCount` correct
- `totalWinningStake` non-zero
- `feeAmount` sensible

---

## E) Post-Resolve Validation

- all 3 tier markets now `Resolved`
- known winner account has non-zero `claimable`
- known loser account has zero `claimable`
- accounting invariant: `total claims + fee <= totalStake`
- UI displays snapshot hash and resolution source

---

## F) Fee Collection

Collect once per tier:

```solidity
collectFee(weekId, tier)
```

Verify:
- transfer to `FEE_RECIPIENT` (Base Safe)
- second call reverts with fee-already-collected path

---

## G) Transparency Post (same day)

Publish:
- weekId
- source URL
- captured timestamp
- snapshot hash
- top10/top5/top1 winner sets
- incident notes (if none: "No incidents")

---

## Emergency Policy

If wrong winners are submitted and finalized:
- pause creation of the next week markets
- publish incident report + corrective plan
- do NOT silently patch

If unresolved due to invalid inputs:
- regenerate winners deterministically
- rerun resolution cleanly (no partial hidden steps)

---

## Operator Signoff Checklist

- [ ] Preconditions checked
- [ ] Winner sets validated
- [ ] Snapshot hash computed and archived
- [ ] Top10 resolved + verified
- [ ] Top5 resolved + verified
- [ ] Top1 resolved + verified
- [ ] Claimability spot-check passed
- [ ] Fees collected to Base Safe
- [ ] Transparency post published
