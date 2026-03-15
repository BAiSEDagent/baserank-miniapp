# BaseRank × Kalshi Portal — Build Scope

## What we're building
A Kalshi prediction market portal layer inside the BaseRank mini app.

BaseRank surfaces Base-ecosystem-relevant Kalshi markets alongside (or instead of) the
current pari-mutuel contract markets.

Kalshi handles: liquidity, order book, settlement, regulation.
BaseRank handles: Base-native UX, market curation, mini app distribution.

---

## Phase 1 — Read-only market portal (no trading)
**Goal:** show Kalshi markets inside BaseRank UI. No auth needed.

### Files to add
```
src/lib/kalshi/client.ts
src/lib/kalshi/types.ts
src/lib/kalshi/filter.ts
src/app/api/kalshi/markets/route.ts
src/components/KalshiMarketCard.tsx
```

### What it does
1. Server-side route fetches markets from Kalshi REST API
2. Filter for Base/crypto/tech adjacent markets
3. Display in UI: title, yes% odds, no% odds, volume, closes at
4. Link out to Kalshi to trade

### Acceptance criteria
- [ ] `/api/kalshi/markets` returns filtered market list
- [ ] `KalshiMarketCard` renders yes/no odds + close time
- [ ] No Kalshi API key exposed client-side
- [ ] Build passes, lint 0 errors

---

## Phase 2 — Real-time prices via WebSocket
**Goal:** live yes/no price updates without polling.

### Files to add/modify
```
src/lib/kalshi/websocket.ts
src/components/KalshiMarketCard.tsx  ← subscribe to live price
```

### Acceptance criteria
- [ ] Prices update in real time on market cards
- [ ] WebSocket reconnects on disconnect
- [ ] No memory leaks on component unmount

---

## Phase 3 — User positions display
**Goal:** show user's open Kalshi positions inside BaseRank.

Requires user to connect their Kalshi account (API key input or OAuth when available).

### Files to add
```
src/app/api/kalshi/positions/route.ts
src/components/KalshiPositionRow.tsx
src/lib/kalshi/auth.ts
```

### Acceptance criteria
- [ ] User can input Kalshi API key (stored in localStorage only)
- [ ] Positions tab shows Kalshi positions alongside BaseRank positions
- [ ] P&L displayed correctly (entry price vs current price × contracts)

---

## Phase 4 — Order placement
**Goal:** user can place a Kalshi trade from within BaseRank UI.

### Flow
1. User selects market + side (YES/NO) + size
2. BaseRank proxies order to `POST /portfolio/orders` via server route
3. Confirmation shown with Kalshi receipt link
4. Position appears in Phase 3 positions tab

### Files to add/modify
```
src/app/api/kalshi/order/route.ts
src/components/KalshiOrderSheet.tsx
```

### Acceptance criteria
- [ ] Order placed and confirmed end-to-end in demo env
- [ ] Error states handled (insufficient balance, market closed, auth failure)
- [ ] No API key stored server-side between requests

---

## Phase 5 — Custom BaseRank market series (post Builders Program)
**Goal:** Kalshi creates a `BASERANK-` market series. We filter and feature them.

### What changes
- `filter.ts` adds `series_ticker.startsWith('BASERANK-')` filter
- Market cards show BaseRank branding for these
- Resolution follows Base leaderboard snapshot

### This unblocks
- BaseRank-specific markets with real liquidity
- Official Base app economy prediction markets
- Potential featured placement in Base app

---

## Anti-gaming note
All Kalshi markets close before the decisive data window.
Phase 5 market proposals should follow the anti-gaming principles in
`docs/ANTI_GAMING_MARKET_DESIGN.md`.

Target: future-interval and yes/no markets, not current-state markets.

---

## Tech constraints
- API key must stay server-side only (route handler, not client)
- User auth token (Phase 3+) stored in localStorage only, never server
- Rate limit: 10 req/s — batch requests, do not call per-card
- Demo env first, production only after full test pass

---

## Replit handoff
When handing to Replit agent, start with Phase 1 only.
Return: commit hash, files changed, build result, working API response sample.
