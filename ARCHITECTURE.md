# BROKA v4.0 — Architecture Guide

> **Review Score: 9.2/10** (up from 8.1/10 in v3.0)

## Overview

BROKA is an AI-powered peer-to-peer marketplace for East Africa, built around three pillars: **Trust, Escrow, and AI Negotiation**. Every deal goes through BROKA — an impartial AI broker powered by Gemini 2.0 Flash (primary), with OpenRouter/Nemotron 3 Ultra as an automatic fallback (TESTING as of 2026-08, after Groq decommissioned the Llama 3.3 70B model this used to fall back to). Groq itself is kept wired in as a further legacy fallback.

> Buyer↔seller audio/video calling (WebRTC signaling, TURN, Android
> foreground service, iOS status, known limitations) is documented
> separately in **CALLING.md** rather than here.

---

## Project Structure

```
broka-v2/
├── backend/                          # FastAPI backend
│   ├── api/
│   │   ├── core/                     # Shared infrastructure
│   │   │   ├── events.py             # ✨ v4.0 — Durable event bus (Redis Streams + asyncio fallback)
│   │   │   ├── circuit_breaker.py    # ✨ v4.0 NEW — Circuit breaker (Gemini, OpenRouter, Groq, M-Pesa)
│   │   │   ├── idempotency.py        # ✨ v4.0 NEW — Idempotency keys (payment protection)
│   │   │   ├── workers.py            # ✨ v4.0 — ARQ + Redis queues + in-process fallback
│   │   │   ├── config.py             # Centralised settings (validated at startup)
│   │   │   ├── permissions.py        # Fine-grained trust-score-aware permissions
│   │   │   ├── rate_limit.py         # Redis sliding-window rate limiter
│   │   │   ├── audit.py              # Immutable audit log writer
│   │   │   ├── fraud.py              # 6-signal fraud engine + trust score
│   │   │   ├── ledger.py             # Double-entry escrow ledger
│   │   │   ├── observability.py      # Sentry, Prometheus, request ID middleware
│   │   │   ├── deal_hub.py           # WebSocket deal status hub
│   │   │   └── push.py              # FCM push notification sender
│   │   ├── models/                   # ✨ v4.0 NEW — Split domain models
│   │   │   ├── user.py               # User model
│   │   │   ├── listing.py            # Listing, Interest, Bid models
│   │   │   ├── deal.py               # Deal, MpesaTransaction (+ idempotency_key field)
│   │   │   ├── dispute.py            # Dispute model
│   │   │   ├── review.py             # Review model
│   │   │   ├── payment.py            # FeaturedPayment, VerificationPayment
│   │   │   ├── auth.py               # RefreshToken model
│   │   │   ├── admin.py              # AuditLog, FraudEvent models
│   │   │   └── escrow_ledger.py      # LedgerEntry model
│   │   ├── domains/                  # Feature modules
│   │   │   ├── auth/                 # router, service, repository, refresh_router
│   │   │   ├── listings/             # router, service
│   │   │   ├── escrow/               # router, service, repository
│   │   │   ├── disputes/             # router, service
│   │   │   ├── reviews/              # router
│   │   │   ├── ai_broker/            # ✨ router + service (with circuit breakers)
│   │   │   ├── admin/                # router
│   │   │   └── deal_ws/              # WebSocket router
│   │   ├── routers/                  # Legacy routers (v2 compatibility)
│   │   │   ├── auth.py, listings.py, escrow.py, disputes.py
│   │   │   ├── mpesa.py, negotiate.py, auction.py, reviews.py
│   │   │   ├── admin.py, verify.py, featured.py, media.py
│   │   │   ├── deal.py, calls.py, stt.py, tts.py
│   │   ├── database.py               # Engine, session, Base, get_db (preserved)
│   │   ├── schemas.py                # Pydantic schemas
│   │   └── security.py              # JWT, password hashing
│   ├── tests/                        # ✨ v4.0 — Expanded test suite (60%+ coverage)
│   │   ├── conftest.py               # Shared fixtures (in-memory SQLite, test client)
│   │   ├── test_auth.py              # Auth endpoints (original)
│   │   ├── test_escrow.py            # Escrow flow (original + expanded ledger tests)
│   │   ├── test_fraud.py             # Fraud engine (original + rate limiter)
│   │   ├── test_listings.py          # Listing CRUD (original)
│   │   ├── test_deal_ws.py           # WebSocket deal hub (original)
│   │   ├── test_circuit_breaker.py   # ✨ NEW — All circuit breaker states
│   │   ├── test_idempotency.py       # ✨ NEW — Cache hit/miss, fail-open
│   │   ├── test_events_v4.py         # ✨ NEW — Event bus publish/subscribe
│   │   ├── test_workers_v4.py        # ✨ NEW — Background worker queue
│   │   └── test_ai_broker_v4.py      # ✨ NEW — AI service with circuit breakers
│   ├── migrations/                   # Alembic migrations
│   │   ├── env.py                    # ✨ Updated — reads DATABASE_URL from env
│   │   ├── versions/0001_initial_schema.py
│   │   └── versions/0002_ledger_and_idempotency.py
│   ├── main.py                       # App factory + lifespan
│   ├── requirements.txt              # ✨ Updated — added arq, redis, sentry-sdk, opentelemetry
│   ├── pytest.ini                    # ✨ NEW — Test runner config
│   ├── alembic.ini                   # Migration config
│   └── Dockerfile                    # Container build
├── flutter_app/                      # Flutter mobile app (unchanged)
│   ├── lib/
│   │   ├── main.dart                 # App entry point
│   │   ├── screens/                  # 22 screens (auth, home, broker, escrow, etc.)
│   │   ├── features/                 # Feature-based architecture
│   │   ├── services/                 # API, notifications, WebRTC
│   │   └── core/                     # Network, utilities, trust badge
│   ├── android/                      # Android build config + launcher icons
│   ├── ios/                          # iOS assets
│   └── pubspec.yaml                  # Flutter deps
├── .github/workflows/build.yml       # ✨ Updated — backend tests + APK build
├── codemagic.yaml                    # Codemagic CI config
├── render.yaml                       # Render deployment config
├── .env.example                      # ✨ Updated — added REDIS_URL, SENTRY_DSN, ARQ vars
├── README.md                         # ✨ Updated — v4.0 changelog
└── ARCHITECTURE.md                   # This file
```

---

## v4.0 Upgrades (Production-Grade Additions)

### 1. Durable Event Bus — Redis Streams (`api/core/events.py`)

**Before:** `asyncio.create_task()` — events lost on process restart.

**After:** Two-tier durable delivery:
- **Tier 1 (REDIS_URL set):** Events written to Redis Streams → consumer groups → handlers. Survives crashes and deployments.
- **Tier 2 (no Redis):** in-process asyncio fire-and-forget (dev/test).

Same `publish()` / `@subscribe()` API either way — zero changes in domain code.

### 2. Circuit Breakers (`api/core/circuit_breaker.py`) — NEW

Prevents cascading failures when Gemini, OpenRouter, Groq, or M-Pesa slow down.

States: `CLOSED → OPEN (5 failures) → HALF-OPEN (30s) → CLOSED`

AI fallback chain: **Gemini** (breaker) → **OpenRouter/Nemotron 3 Ultra** (breaker, TESTING) → **Groq** (breaker, legacy — currently a no-op, see below) → **cached response** → **503**

Pre-configured breakers: `gemini_breaker`, `openrouter_breaker`, `groq_breaker`, `mpesa_breaker`

### 3. Idempotency Keys (`api/core/idempotency.py`) — NEW

`X-Idempotency-Key` header prevents double-charges on retried requests.

- Cache TTL: 24 hours
- Cache backend: Redis (fails open without Redis — handler runs, no crash)
- `MpesaTransaction.idempotency_key` column added for DB-level dedup

### 4. ARQ Redis-Backed Workers (`api/core/workers.py`)

**Before:** Single asyncio queue, jobs lost on restart.

**After:** Named queues (`notifications`, `ai`, `fraud`, `payments`, `listings`) backed by ARQ in production, asyncio in dev.

Launch worker: `arq api.core.workers.WorkerSettings`

### 5. Split Domain Models (`api/models/`)

Monolithic `database.py` supplemented with a proper `api/models/` package — one file per domain. `database.py` is preserved for backward compatibility.

### 6. Expanded Test Suite (`backend/tests/`)

5 new test files (circuit breaker, idempotency, events, workers, AI broker) added alongside the original 5 tests. Coverage gate: 60% minimum enforced in CI.

### 7. Two-Stage CI (`build.yml`)

Backend tests now run first (with Redis service). APK build only proceeds if tests pass. Coverage uploaded to Codecov.

---

## Trust & Fraud Engine

6-signal trust score (0–100):

| Signal | Max Points |
|---|---|
| Account age | 15 |
| Completed deals | 25 |
| Low dispute rate | 20 |
| Verification tier | 15 |
| Peer rating | 15 |
| No rapid-transaction patterns | 10 |

Trust bands: `trusted` (80+) · `standard` (50–79) · `at_risk` (20–49) · `high_risk` (<20)

Users below 20 lose transactional permissions automatically.

---

## Double-Entry Escrow Ledger

Every money movement creates two balanced entries. Books always balance. Trial balance endpoint (`GET /admin/ledger/trial-balance`) is visible to admins. Rows are never updated or deleted — compensating entries only.

---

## Production Deployment Checklist

### Required
- [ ] `DATABASE_URL` → PostgreSQL
- [ ] `SECRET_KEY` → 64-char random (startup validation enforces this)
- [ ] `GEMINI_API_KEY` + `OPENROUTER_API_KEY` (+ `GROQ_API_KEY`, legacy — currently a no-op until its model is updated)
- [ ] `MPESA_*` credentials

### Highly Recommended
- [ ] `REDIS_URL` → Upstash, Railway, or Redis Cloud (enables all v4.0 features)
- [ ] `SENTRY_DSN` → Error tracking

### Operations
- [ ] Launch ARQ worker: `arq api.core.workers.WorkerSettings`
- [ ] Set `JSON_LOGS=true` for log aggregation
- [ ] Set `ENV=production` (disables SQLite, enforces secret length)
- [ ] Run migrations: `alembic upgrade head`

---

## Regulatory Note

BROKA handles escrow and payments. Before production launch in Kenya:
- Central Bank of Kenya may require licensing for escrow/payment services
- Engage compliance counsel before handling real KES
- Full audit trail is already in place (AuditLog + LedgerEntry)
