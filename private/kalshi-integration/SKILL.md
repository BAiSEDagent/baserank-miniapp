---
name: kalshi-baserank
description: Query Kalshi prediction markets and surface them in the BaseRank UI. Use when fetching Kalshi market data, filtering Base-adjacent markets, checking prices or order books, or building the Kalshi portal layer inside BaseRank. NOT for Polymarket (use polyclaw skill for that).
---

# Kalshi × BaseRank Integration Skill

## What this skill does
Connects the BaseRank app to Kalshi's API so you can:
- Fetch and filter prediction market data from Kalshi
- Display Kalshi markets inside the BaseRank UI
- Route order placement to Kalshi on behalf of users
- Monitor open positions tied to Base-ecosystem markets

## Auth
Kalshi uses **RSA key-pair auth**, not simple API tokens.

```bash
# Generate key pair (one-time)
openssl genrsa -out kalshi_private.pem 2048
openssl rsa -in kalshi_private.pem -pubout -out kalshi_public.pem
```

Register the public key at kalshi.com/settings/api-keys.

Store `KALSHI_API_KEY_ID` and `KALSHI_PRIVATE_KEY_PATH` in `.env.local`.

Demo environment base URL: `https://demo-api.kalshi.co/trade-api/v2`
Production base URL: `https://trading-api.kalshi.com/trade-api/v2`

## Key endpoints
See `references/kalshi-api-endpoints.md` for full list.

### Most useful for BaseRank
```
GET  /events              → list events (filter by status, category)
GET  /events/{ticker}     → single event detail
GET  /markets             → list markets
GET  /markets/{ticker}    → single market (price, volume, close time)
GET  /portfolio/positions → user positions (requires auth)
POST /portfolio/orders    → place order (requires auth)
```

## Filtering Base-adjacent markets
Kalshi has no "Base" category yet. Filter approach:

```typescript
// Step 1: fetch all open events
const events = await kalshi.getEvents({ status: 'open', limit: 200 })

// Step 2: filter by keyword match against title/subtitle
const baseMarkets = events.filter(e =>
  /base|coinbase|ethereum|crypto|defi|web3/i.test(e.title + e.sub_title)
)

// Step 3: until Builders Program custom markets exist,
// surface general crypto/tech markets as proxy inventory
```

Once Builders Program markets exist, filter by `series_ticker` prefix.

## BaseRank portal architecture

```
User wallet (Coinbase Smart Wallet)
  ↕
BaseRank frontend
  ↕ Kalshi REST/WS API
Kalshi exchange (settlement, order book, resolution)
```

Users need a separate Kalshi account for trading on their markets.
BaseRank acts as a discovery/filter layer + eventually market proposer.

## Files to touch for integration
```
src/lib/kalshi/               ← new
  client.ts                   ← REST client + auth
  types.ts                    ← KalshiEvent, KalshiMarket, KalshiPosition
  filter.ts                   ← Base-adjacent market filter logic

src/app/api/kalshi/
  markets/route.ts            ← server-side proxy (hides API key)
  positions/route.ts          ← user position fetch (requires user auth token)

src/components/
  KalshiMarketCard.tsx        ← display odds, volume, close time
  KalshiPositionRow.tsx       ← show existing positions

src/app/page.tsx              ← add Kalshi tab or section
```

## WebSocket for real-time prices
```typescript
const ws = new WebSocket('wss://trading-api.kalshi.com/trade-api/ws/v2')

ws.send(JSON.stringify({
  id: 1,
  cmd: 'subscribe',
  params: {
    channels: ['ticker'],
    market_tickers: ['KXBASE-25DEC31-Y', 'KXCRYPTO-...']
  }
}))
```

Subscribe to `ticker` channel for live yes/no price updates.

## Order placement flow
```
1. User clicks "Trade on Kalshi" in BaseRank UI
2. BaseRank redirects to Kalshi OAuth or asks for API key
3. User places order → BaseRank proxies to POST /portfolio/orders
4. Show confirmation with Kalshi market link
```

Note: Kalshi's order system uses contracts, not USDC directly.
Each contract settles at $1.00 on resolution.
Price is expressed as cents (e.g., 0.67 = 67¢ per YES contract).

## Rate limits
- Default: 10 req/s REST, 100 msg/s WebSocket
- Burst up to 20 req/s briefly
- Use server-side proxy route to protect the key and batch requests

## Environment variables needed
```
KALSHI_API_KEY_ID=
KALSHI_PRIVATE_KEY_PATH=./private/kalshi_private.pem
KALSHI_ENV=demo   # or production
```

## Next step: Builders Program
To get BaseRank-specific markets created on Kalshi:
- Apply at kalshi.com/builders
- Pitch: Base app economy prediction markets as a mini app
- Request custom `BASERANK-` series ticker
- Reference: Kalshi already did this for World (Worldcoin mini app)

See `references/builders-program-pitch.md` for the pitch template.
