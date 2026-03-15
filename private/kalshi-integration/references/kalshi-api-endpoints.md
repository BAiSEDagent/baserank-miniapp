# Kalshi API Reference — Key Endpoints

Base URL (production): `https://trading-api.kalshi.com/trade-api/v2`
Base URL (demo):       `https://demo-api.kalshi.co/trade-api/v2`
Full docs:             `https://docs.kalshi.com`
OpenAPI spec:          `https://docs.kalshi.com/openapi.yaml`
llms.txt index:        `https://docs.kalshi.com/llms.txt`

---

## Public (no auth required)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/exchange/status` | Exchange open/closed status |
| GET | `/events` | List all events (filter: status, category, limit, cursor) |
| GET | `/events/{ticker}` | Single event detail |
| GET | `/events/{ticker}/candlesticks` | Aggregated price history |
| GET | `/markets` | List markets (filter: event_ticker, status, limit) |
| GET | `/markets/{ticker}` | Single market detail (price, volume, close_time, open_time) |
| GET | `/markets/{ticker}/candlesticks` | Candlestick OHLCV data |
| GET | `/markets/{ticker}/orderbook` | Live order book (depth) |
| GET | `/series` | List market series |
| GET | `/series/{ticker}` | Single series |

---

## Authenticated (requires API key)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/portfolio/balance` | Account balance |
| GET | `/portfolio/positions` | Open positions |
| GET | `/portfolio/fills` | Trade fill history |
| GET | `/portfolio/orders` | Open + past orders |
| POST | `/portfolio/orders` | Place an order |
| DELETE | `/portfolio/orders/{order_id}` | Cancel an order |
| GET | `/account` | Account info |
| GET | `/account/api-limits` | API tier limits |

---

## Order payload (POST /portfolio/orders)

```json
{
  "ticker": "KXCRYPTO-25DEC31-Y",
  "action": "buy",
  "side": "yes",
  "type": "limit",
  "count": 100,
  "yes_price": 67,
  "no_price": 33,
  "client_order_id": "baserank-uuid-here"
}
```

- `count` = number of contracts (each settles at $1.00)
- `yes_price` / `no_price` in cents (1–99)
- `type`: `limit` or `market`
- `action`: `buy` or `sell`

---

## WebSocket

Endpoint: `wss://trading-api.kalshi.com/trade-api/ws/v2`

Subscribe command:
```json
{
  "id": 1,
  "cmd": "subscribe",
  "params": {
    "channels": ["ticker", "orderbook_delta"],
    "market_tickers": ["KXCRYPTO-25DEC31-Y"]
  }
}
```

Channels: `ticker`, `orderbook_delta`, `fill`, `order`

---

## Market object shape (key fields)

```typescript
interface KalshiMarket {
  ticker: string           // e.g. "KXCRYPTO-25DEC31-Y"
  event_ticker: string
  title: string
  subtitle: string
  yes_bid: number          // cents
  yes_ask: number          // cents
  no_bid: number
  no_ask: number
  last_price: number
  volume: number           // contracts traded
  open_interest: number
  close_time: string       // ISO8601
  status: 'open' | 'closed' | 'settled'
  result: 'yes' | 'no' | ''
}
```

---

## Auth flow (RSA)

```typescript
import { createSign } from 'crypto'
import { readFileSync } from 'fs'

function signRequest(method: string, path: string, timestamp: number, body: string) {
  const message = `${timestamp}${method}${path}${body}`
  const sign = createSign('SHA256')
  sign.update(message)
  const privateKey = readFileSync(process.env.KALSHI_PRIVATE_KEY_PATH!)
  return sign.sign(privateKey, 'base64')
}

// Headers required on authenticated requests:
// KALSHI-ACCESS-KEY: <api_key_id>
// KALSHI-ACCESS-TIMESTAMP: <unix_ms>
// KALSHI-ACCESS-SIGNATURE: <base64 signature>
```
