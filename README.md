# BaseRank Mini App

Base mini app for weekly prediction markets on app leaderboard outcomes (Top10 / Top5 / #1).

## Included in this repo

- `src/` Next.js mobile-first UI shell (wallet connect + bet sheet + tx stepper)
- `contracts/BaseRankMarket.sol` single-market-per-(week,tier) parimutuel contract

## Environment

Create `.env.local`:

```bash
NEXT_PUBLIC_MARKET_ADDRESS=0x...
```

## Run app

```bash
npm install
npm run dev
```

## Contract fee basis

Fee is calculated at resolve time as:

```solidity
feeAmount = (market.totalStake * feeBps) / 10_000
```

Default is `feeBps = 100` (1%), capped at `500` (5%).

## Core contract notes

- One market per `weekId + tier`
- Bets are placed by `appId` inside that market
- Winner set validated on resolve:
  - Top10 => 1..10 winners
  - Top5 => 1..5 winners
  - Top1 => exactly 1 winner
- Payout:

```solidity
payout = (userWinningStake * (totalStake - feeAmount)) / totalWinningStake
```

- Includes `claimable(weekId, tier, user)` view for frontend
- `MarketResolved` emits `winnerCount` and `totalWinningStake`

## Quick checks

```bash
npm run lint
npm run build
```
