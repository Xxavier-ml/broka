"""
BROKA - FastAPI Backend v6.0
Platform architecture: Event Catalog + Workflow Versioning + Distributed Tracing + Zeno Events.
Domain-module architecture + event bus + fraud engine + background workers.
Backward-compatible: legacy routers kept alongside new domain routers.
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from api.database import init_db
from api.core.config import settings, validate_startup
from api.core.workers import worker
from api.security import validate_secret_key
from api.core.observability import init_observability, _init_event_counter

# ── Distributed Tracing (init before routes so auto-instrumentation applies) ──
from api.core.tracing import init_tracing
init_tracing(service_name="broka-backend")

# ── Legacy routers (kept for backward compatibility) ─────────────────────────
from api.routers import (
    negotiate, auction, deal, mpesa,
    verify, featured, media, sms,
)
# Optional routers (may not exist in all deployments)
try:
    from api.routers import tts
    _has_tts = True
except ImportError:
    _has_tts = False

try:
    from api.routers import stt
    _has_stt = True
except ImportError:
    _has_stt = False

try:
    from api.routers import calls
    _has_calls = True
except ImportError:
    _has_calls = False

try:
    from api.routers import escrow as legacy_escrow
    _has_legacy_escrow = True
except ImportError:
    _has_legacy_escrow = False

# ── New v3.0 domain routers ───────────────────────────────────────────────────
from api.domains.auth.router       import router as auth_router
from api.domains.listings.router   import router as listings_router
from api.domains.showcase.router   import router as showcase_router, preview_router as showcase_preview_router
from api.domains.categories.router import router as categories_router
from api.domains.trending.router   import router as trending_router
from api.domains.traders.router    import router as traders_router
from api.domains.auctions.router   import router as auctions_router
from api.domains.auction_ws.router import router as auction_ws_router
from api.domains.buy_agent.router  import router as buy_agent_router
from api.domains.escrow.router     import router as escrow_router
from api.domains.disputes.router   import router as disputes_router
# v5.0 dispute engine — same router file, /disputes/v2/* endpoints auto-registered
from api.domains.reviews.router    import router as reviews_router
from api.domains.ai_broker.router  import router as ai_broker_router
from api.domains.admin.router      import router as admin_router
from api.domains.deal_ws.router    import router as deal_ws_router
from api.domains.auth.refresh_router import router as refresh_router

# ── Wire Event Catalog subscribers (must import after router imports) ─────────
# All six of these register on api.core.event_catalog's @subscribe_to, not the
# legacy api.core.events @subscribe bus - the legacy bus only invokes
# in-process handlers when REDIS_URL is unset, so anything still registered
# there would silently stop firing under Redis (the recommended production
# config). See each file's own header comment for the full explanation
# (redesign-guide audit, 2026-08-11 - deal_hub/auction_hub/push/
# trader_specialization/buy_agent were all found still on the legacy bus and
# migrated this pass; zeno_subscribers was already correct).
import api.core.deal_hub_subscribers  # noqa: F401  registers deal WS broadcasts
import api.core.auction_hub_subscribers  # noqa: F401  registers auction WS broadcasts
import api.core.push_subscribers      # noqa: F401  registers FCM push notifications
import api.core.zeno_subscribers                    # noqa: F401  Zeno reacts to platform events
import api.core.trader_specialization_subscribers   # noqa: F401  derives seller specializations from listings
import api.core.buy_agent_subscribers               # noqa: F401  matches new listings against standing buy requests


# ── Lifespan ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # ── Startup validation ────────────────────────────────────────────────────
    validate_secret_key()   # fail fast if SECRET_KEY == default in production
    validate_startup()      # SQLite-in-prod guard + warn about missing Redis/Sentry
    await init_db()
    await worker.start()
    _init_event_counter()   # Prometheus event counter (no-op if prom not installed)
    from api.core.workers import start_periodic_sweep, stop_periodic_sweep
    await start_periodic_sweep()  # enforces AI-announced deal auto-resolution timers

    # Log registered workflow versions and event subscribers
    from api.core.workflow import all_versions, CURRENT_VERSION
    from api.core.event_catalog import handler_count
    logging.getLogger(__name__).info(
        "🚀 BROKA v6.0 started  workflow_versions=%s current=%s event_handlers=%s",
        all_versions(), CURRENT_VERSION, len(handler_count()),
    )
    yield
    # ── Shutdown ──────────────────────────────────────────────────────────────
    await stop_periodic_sweep()
    await worker.stop()
    logging.getLogger(__name__).info("🛑 BROKA v6.0 stopped")


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="BROKA - AI Marketplace API",
    description="AI-powered peer-to-peer marketplace for East Africa.",
    version="6.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── Observability (Sentry + request IDs + latency logging + Prometheus) ───────
init_observability(app)


# ── CORS ──────────────────────────────────────────────────────────────────────

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=settings.allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Global exception handler ──────────────────────────────────────────────────

@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception):
    logging.getLogger(__name__).error("Unhandled exception: %s", exc, exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error. Our team has been notified."},
    )


# ── New v3.0 Domain Routers ───────────────────────────────────────────────────
app.include_router(auth_router,       prefix="/auth",       tags=["Auth v3"])
app.include_router(listings_router,   prefix="/listings",   tags=["Listings v3"])
app.include_router(showcase_router,   prefix="/listings",   tags=["AI Showcase"])
app.include_router(showcase_preview_router, prefix="/showcase", tags=["AI Showcase"])
app.include_router(categories_router, prefix="/categories", tags=["Categories"])
app.include_router(trending_router,   prefix="/trending",   tags=["Trending"])
app.include_router(traders_router,    prefix="/traders",    tags=["Traders"])
app.include_router(auctions_router,   prefix="/auctions",   tags=["Auctions"])
app.include_router(auction_ws_router, prefix="/auction-ws", tags=["Auction WS"])
app.include_router(buy_agent_router,  prefix="/buy-agent-requests", tags=["Buy-Agent"])
app.include_router(escrow_router,     prefix="/deal",       tags=["Escrow/Deal v3"])
app.include_router(disputes_router,   prefix="/disputes",   tags=["Disputes v5"])
app.include_router(reviews_router,    prefix="/reviews",    tags=["Reviews v3"])
# NOTE: legacy negotiate.router is registered BEFORE ai_broker_router (both
# mount at /negotiate). FastAPI resolves path collisions by registration
# order, and both define POST /chat. The legacy free_chat() is the one
# Flutter actually needs - it supports image_base64 (Zeno's photo-analysis
# feature on product_screen.dart), per-surface system prompts (system_override
# "zeno" vs the default broker persona), and language - none of which the
# newer AIBrokerService.broker_chat() implements. With the domain router
# first (the previous order), every /negotiate/chat call silently got the
# generic broker persona with images dropped on the floor, even from
# zeno_screen.dart and seller_dashboard_screen.dart which explicitly ask for
# the Zeno persona. ai_broker_router's OTHER routes (/scam-check,
# /price-recommend, /dispute-analysis) don't collide with anything in
# negotiate.router, so they're unaffected by this ordering either way.
app.include_router(negotiate.router,  prefix="/negotiate",  tags=["Negotiate (legacy)"])
app.include_router(ai_broker_router,  prefix="/negotiate",  tags=["AI Broker v3"])
app.include_router(admin_router,      prefix="/admin",      tags=["Admin v3"])
app.include_router(deal_ws_router,    prefix="/deal-ws",    tags=["Deal WebSocket"])
app.include_router(refresh_router,    prefix="/auth",       tags=["Auth — Token Refresh"])

# ── Legacy Routers (preserved for Flutter compatibility) ──────────────────────
# negotiate.router is registered above (see note near ai_broker_router) so its
# /chat implementation wins the path collision instead of being shadowed.
app.include_router(auction.router,    prefix="/auction",    tags=["Auction"])
app.include_router(mpesa.router,      prefix="/mpesa",      tags=["M-Pesa"])
app.include_router(verify.router,     prefix="/verify",     tags=["Verification"])
app.include_router(featured.router,   prefix="/featured",   tags=["Featured"])
app.include_router(sms.router,        prefix="/sms",        tags=["SMS"])
app.include_router(media.router,      prefix="/media",      tags=["Media/WebSocket"])

if _has_tts:
    app.include_router(tts.router,    prefix="/tts",        tags=["TTS"])
if _has_stt:
    app.include_router(stt.router,    prefix="/stt",        tags=["STT"])
if _has_calls:
    app.include_router(calls.router,  prefix="/calls",      tags=["Calls"])
if _has_legacy_escrow:
    app.include_router(legacy_escrow.router, prefix="/escrow", tags=["Escrow (legacy)"])


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/", tags=["Health"])
async def root():
    return {
        "status":  "online",
        "service": "BROKA API",
        "version": "6.0.0",
        "features": [
            "domain_modules",
            "event_catalog",        # NEW v6: DOMAIN.EVENT_NAME catalog
            "workflow_versioning",  # NEW v6: rules locked at deal creation
            "distributed_tracing",  # NEW v6: OpenTelemetry spans
            "zeno_event_reactions", # NEW v6: Zeno subscribes to events
            "event_bus",
            "fraud_engine",
            "trust_scores",
            "audit_logs",
            "rate_limiting",
            "background_workers",
            "ai_broker_v3",
            "scam_detection",
            "price_recommendations",
            "deal_status_websocket",
            "dispute_engine_v5",
        ],
    }


@app.get("/health", tags=["Health"])
async def health():
    """Basic liveness probe — returns 200 if the process is alive."""
    return {"status": "healthy", "version": "6.0.0"}


@app.get("/ready", tags=["Health"])
async def ready():
    """
    Readiness probe — checks DB connectivity.
    Returns 200 when ready to serve traffic, 503 if not.
    Used by load balancers (Render, Kubernetes) to gate traffic.
    """
    from fastapi.responses import JSONResponse
    from sqlalchemy import text
    try:
        async with __import__("api.database", fromlist=["AsyncSessionLocal"]).AsyncSessionLocal() as db:
            await db.execute(text("SELECT 1"))
        db_ok = True
    except Exception as e:
        logging.getLogger(__name__).error("[ready] DB check failed: %s", e)
        db_ok = False

    redis_ok = True
    if settings.redis_enabled:
        try:
            import redis.asyncio as aioredis
            r = aioredis.from_url(settings.redis_url, socket_connect_timeout=2)
            await r.ping()
            await r.aclose()
        except Exception as e:
            logging.getLogger(__name__).warning("[ready] Redis check failed: %s", e)
            redis_ok = False

    from api.core.workflow import CURRENT_VERSION, all_versions
    from api.core.event_catalog import handler_count

    status_code = 200 if db_ok else 503
    return JSONResponse(
        status_code=status_code,
        content={
            "status":           "ready" if db_ok else "not_ready",
            "db":               "ok" if db_ok else "error",
            "redis":            "ok" if redis_ok else "error" if settings.redis_enabled else "not_configured",
            "version":          "6.0.0",
            "workflow_current": CURRENT_VERSION,
            "workflow_all":     all_versions(),
            "event_handlers":   handler_count(),
        },
    )


@app.get("/live", tags=["Health"])
async def live():
    """Kubernetes liveness probe — always returns 200 if the process is running."""
    return {"alive": True}
