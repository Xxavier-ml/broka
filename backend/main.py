"""
BROKA - FastAPI Backend
All routers registered. CORS configured via ALLOWED_ORIGINS env var.
"""

import os
import logging
logging.basicConfig(level=logging.INFO)
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from api.database import init_db
from api.routers import (
    listings, auth, negotiate, auction, deal, mpesa, tts, calls,
    disputes, verify, featured, reviews, stt, admin, escrow,
)
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(
    title="BROKA - AI Marketplace API",
    version="2.2.0",
    lifespan=lifespan,
)

# ── CORS ──────────────────────────────────────────────────────────────────────
# Production: set ALLOWED_ORIGINS env var to a comma-separated list,
# e.g. "https://broka.app,https://www.broka.app"
# Dev: defaults to "*" so local Flutter / web preview works out of the box.
_raw_origins = os.getenv("ALLOWED_ORIGINS", "*").strip()
if _raw_origins == "*" or not _raw_origins:
    _origins = ["*"]
    _allow_credentials = False
else:
    _origins = [o.strip() for o in _raw_origins.split(",") if o.strip()]
    _allow_credentials = True

app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=_allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routers ───────────────────────────────────────────────────────────────────
app.include_router(auth.router,      prefix="/auth",      tags=["Auth"])
app.include_router(listings.router,  prefix="/listings",  tags=["Listings"])
app.include_router(negotiate.router, prefix="/negotiate", tags=["Negotiation"])
app.include_router(auction.router,   prefix="/auction",   tags=["Auction"])
app.include_router(deal.router,      prefix="/deal",      tags=["Deal"])
app.include_router(escrow.router,    prefix="/escrow",    tags=["Escrow"])
app.include_router(mpesa.router,     prefix="/mpesa",     tags=["M-Pesa"])
app.include_router(tts.router,       prefix="/tts",       tags=["TTS"])
app.include_router(stt.router,       prefix="/stt",       tags=["STT"])
app.include_router(calls.router,     prefix="/calls",     tags=["Calls"])
app.include_router(disputes.router,  prefix="/disputes",  tags=["Disputes"])
app.include_router(verify.router,    prefix="/verify",    tags=["Verification"])
app.include_router(featured.router,  prefix="/featured",  tags=["Featured"])
app.include_router(reviews.router,   prefix="/reviews",   tags=["Reviews"])
app.include_router(admin.router,     prefix="/admin",     tags=["Admin"])


@app.get("/", tags=["Health"])
async def root():
    return {"status": "online", "service": "BROKA API", "version": "2.2.0"}


@app.get("/health", tags=["Health"])
async def health():
    return {"status": "healthy"}
