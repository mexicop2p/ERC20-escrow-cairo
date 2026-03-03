# MexicoP2P Partner API

MexicoP2P lets fintechs offer crypto to peso rails without spending months and millions building compliance, escrow, and banking infrastructure from scratch.

One API. One portal. Everything solved.

---

## Overview

MexicoP2P provides a peer-to-peer crypto-to-peso ramp for the Mexican market. Your users trade USDC and USDT for Mexican Pesos via SPEI, with escrow protection and built-in compliance.

You integrate once. We handle escrow, payment verification, dispute resolution, AML scoring, and SAT reporting.

---

## Authentication

All API requests require an API key via the `X-API-Key` header.

```
X-API-Key: mp2p_your_api_key
```

API keys are issued when your partner account is approved. Optionally configure IP whitelists and HMAC request signing for additional security.

---

## Base URL

```
https://api.mexicop2p.com/api/v1
```

---

## Endpoints

### Orders

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/orders` | List orders (marketplace or filtered by status) |
| `POST` | `/orders` | Create a new order on behalf of a user |
| `GET` | `/orders/:id` | Get order details |

### Users

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/users` | List your partner users |
| `GET` | `/users/:ref` | Get a user by your internal reference |
| `POST` | `/users/:ref` | Create or update a partner user |
| `POST` | `/users/:ref/kyc` | Start KYC verification for a user |

### Quotes

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/quotes` | Get a real-time exchange rate quote |
| `GET` | `/exchange-rate` | Get the current USD/MXN rate |

### Webhooks

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/webhooks` | List webhook delivery history |

### Health

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Health check |

---

## Order Lifecycle

```
PENDING_DEPOSIT → ACTIVE → LOCKED → VERIFIED → COMPLETED
```

1. **Create** — Seller creates an order specifying token, amount, and price.
2. **Deposit** — Seller deposits crypto to escrow.
3. **Lock** — Buyer locks the order and has a window to pay.
4. **Verify** — Buyer submits SPEI payment proof (CEP). We verify it against Banxico.
5. **Release** — Escrow releases crypto to buyer. Order complete.

Disputes are handled automatically with fraud scoring and admin resolution.

---

## Webhook Events

Configure a webhook URL in your partner settings. We send signed events for every order state change.

| Event | Description |
|-------|-------------|
| `order.created` | A new order was created |
| `order.locked` | A buyer locked the order |
| `order.payment_verified` | SPEI payment was verified via CEP |
| `order.completed` | Escrow released, order complete |
| `order.refunded` | Crypto refunded to seller |
| `order.lock_expired` | Buyer's lock window expired |
| `order.disputed` | A dispute was opened |
| `order.dispute_resolved` | Dispute resolved by admin |

All webhook payloads are signed with HMAC-SHA256. Delivery is retried up to 5 times with exponential backoff.

---

## Supported Tokens

| Token | Network |
|-------|---------|
| USDC | Starknet |
| USDT | Starknet |

---

## Partner Tiers

| Tier | Rate Limit | Volume |
|------|-----------|--------|
| Free | 50 req/min | Limited |
| Starter | 200 req/min | Daily cap |
| Pro | 1,000 req/min | Monthly cap |
| Enterprise | 5,000 req/min | Unlimited |

---

## Compliance

Every order includes AML risk scoring, FX rate snapshots from Banxico, and SPEI payment verification against the central bank. SAT-ready tax reports are generated automatically.

Your users trade. We handle the compliance.

---

## Get Started

1. Apply for a partner account at [mexicop2p.com/partners](https://mexicop2p.com/partners)
2. Complete KYB verification
3. Receive your API key
4. Integrate and launch

---

## Support

Questions? Reach us at partners@mexicop2p.com
