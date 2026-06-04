"""
BROKA — FastAPI Backend
All routers registered. CORS configured via ALLOWED_ORIGINS env var.
"""

import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from api.database import init_db
from api.routers import listings, auth, negotiate, auction, deal
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(
    title="BROKA — AI Marketplace API",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routers ───────────────────────────────────────────────────────────────────
app.include_router(auth.router,      prefix="/auth",      tags=["Auth"])
app.include_router(listings.router,  prefix="/listings",  tags=["Listings"])
app.include_router(negotiate.router, prefix="/negotiate", tags=["Negotiation"])
app.include_router(auction.router,   prefix="/auction",   tags=["Auction"])
app.include_router(deal.router,      prefix="/deal",      tags=["Deal"])


@app.get("/", tags=["Health"])
async def root():
    return {"status": "online", "service": "BROKA API", "version": "2.0.0"}


@app.get("/health", tags=["Health"])
async def health():
    return {"status": "healthy"}
