"""
BROKA - Database Layer
SQLite for local dev; PostgreSQL for production (Render).
"""

import os
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import declarative_base, sessionmaker, relationship
from sqlalchemy import (
    Column, String, Float, Integer, Boolean,
    DateTime, ForeignKey, Enum, Text,
)
from datetime import datetime
import enum
import uuid


def _build_db_url() -> str:
    url = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./broka.db")
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql+asyncpg://", 1)
    elif url.startswith("postgresql://") and "+asyncpg" not in url:
        url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
    return url


DATABASE_URL = _build_db_url()
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_async_engine(DATABASE_URL, echo=False, connect_args=connect_args)
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()


# ─── Enums ───────────────────────────────────────────────────────────────────

class ListingType(str, enum.Enum):
    direct  = "direct"
    auction = "auction"

class ListingStatus(str, enum.Enum):
    active    = "active"
    pending   = "pending"
    completed = "completed"
    cancelled = "cancelled"

class DealStatus(str, enum.Enum):
    negotiating = "negotiating"
    agreed      = "agreed"
    paid        = "paid"          # M-Pesa commission confirmed (funds held in escrow)
    released    = "released"      # buyer confirmed delivery → seller paid out
    refunded    = "refunded"      # dispute resolved in buyer's favour
    disputed    = "disputed"      # open dispute, funds frozen
    cancelled   = "cancelled"

class MpesaStatus(str, enum.Enum):
    pending = "pending"
    success = "success"
    failed  = "failed"


# ─── Models ──────────────────────────────────────────────────────────────────

class User(Base):
    __tablename__ = "users"
    id                 = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name               = Column(String, nullable=False)
    nickname           = Column(String, nullable=True)   # preferred name for AI/broker
    email              = Column(String, unique=True, nullable=False, index=True)
    phone              = Column(String, nullable=True)
    password_hash      = Column(String, nullable=False)
    lat                = Column(Float, nullable=True)
    lng                = Column(Float, nullable=True)
    rating             = Column(Float, default=5.0)
    completed_deals    = Column(Integer, default=0)
    is_verified        = Column(Boolean, default=False)
    verify_tier        = Column(String, nullable=True)      # "basic" | "gold"
    verify_expires_at  = Column(DateTime, nullable=True)    # when badge expires
    preferred_language = Column(String, default="english", nullable=True)
    location_visible   = Column(Boolean, default=True)   # user controls if location shows on public profile
    biometric_enrolled = Column(String, nullable=True)   # 'fingerprint' | 'face' | None
    # Profile selfie stored as base64 string
    profile_photo      = Column(Text, nullable=True)
    fcm_token          = Column(String, nullable=True)   # Firebase Cloud Messaging device token
    is_admin           = Column(Boolean, default=False, nullable=False)
    last_seen          = Column(DateTime, nullable=True)  # updated by /auth/heartbeat
    created_at         = Column(DateTime, default=datetime.utcnow)

    listings = relationship("Listing", back_populates="seller", foreign_keys="Listing.seller_id")


class Listing(Base):
    __tablename__ = "listings"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    seller_id     = Column(String, ForeignKey("users.id"), nullable=False)
    name          = Column(String, nullable=False)
    description   = Column(Text, nullable=True)
    category      = Column(String, nullable=False)
    price         = Column(Float, nullable=False)
    lat           = Column(Float, nullable=False)
    lng           = Column(Float, nullable=False)
    location_name = Column(String, nullable=True)
    listing_type  = Column(Enum(ListingType), default=ListingType.direct)
    status        = Column(Enum(ListingStatus), default=ListingStatus.active)
    views         = Column(Integer, default=0)
    target_bidders= Column(Integer, nullable=True)
    auction_date  = Column(DateTime, nullable=True)
    reserve_price = Column(Float, nullable=True)
    verified_photos = Column(Text, nullable=True)
    verified_video  = Column(Text, nullable=True)
    advert_video    = Column(Text, nullable=True)
    is_featured     = Column(Boolean, default=False)          # pinned to top of feed
    featured_until  = Column(DateTime, nullable=True)         # auto-expires
    created_at    = Column(DateTime, default=datetime.utcnow)

    seller = relationship("User", back_populates="listings", foreign_keys=[seller_id])
    bids   = relationship("Bid", back_populates="listing")


class Interest(Base):
    __tablename__ = "interests"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = Column(String, ForeignKey("listings.id"))
    buyer_id    = Column(String, ForeignKey("users.id"))
    offer_price = Column(Float, nullable=True)
    created_at  = Column(DateTime, default=datetime.utcnow)


class NegotiationMessage(Base):
    __tablename__ = "negotiation_messages"
    id             = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id     = Column(String, ForeignKey("listings.id"))
    sender_id      = Column(String, nullable=False)
    role           = Column(String, nullable=False)
    recipient_role = Column(String, nullable=True)
    content        = Column(Text, nullable=False)
    created_at     = Column(DateTime, default=datetime.utcnow)


class Bid(Base):
    __tablename__ = "bids"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = Column(String, ForeignKey("listings.id"))
    bidder_id   = Column(String, ForeignKey("users.id"))
    amount      = Column(Float, nullable=False)
    created_at  = Column(DateTime, default=datetime.utcnow)

    listing = relationship("Listing", back_populates="bids")


class Deal(Base):
    __tablename__ = "deals"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id   = Column(String, ForeignKey("listings.id"))
    seller_id    = Column(String, ForeignKey("users.id"))
    buyer_id     = Column(String, ForeignKey("users.id"))
    agreed_price = Column(Float, nullable=False)
    commission   = Column(Float, nullable=False)
    status       = Column(Enum(DealStatus), default=DealStatus.agreed)
    delivery_confirmed_at = Column(DateTime, nullable=True)   # buyer confirmed → funds released
    released_at  = Column(DateTime, nullable=True)
    refunded_at  = Column(DateTime, nullable=True)
    created_at   = Column(DateTime, default=datetime.utcnow)

    mpesa_transactions = relationship("MpesaTransaction", back_populates="deal")


class MpesaTransaction(Base):
    __tablename__ = "mpesa_transactions"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id             = Column(String, ForeignKey("deals.id"), nullable=False)
    buyer_id            = Column(String, ForeignKey("users.id"), nullable=False)
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)   # e.g. QJL82XXXXXX
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    created_at          = Column(DateTime, default=datetime.utcnow)

    deal = relationship("Deal", back_populates="mpesa_transactions")



class DisputeStatus(str, enum.Enum):
    open      = "open"
    resolved  = "resolved"
    dismissed = "dismissed"

class DisputeResolution(str, enum.Enum):
    release = "release"   # pay seller
    refund  = "refund"    # return to buyer
    split   = "split"     # partial resolution

class Dispute(Base):
    __tablename__ = "disputes"
    id              = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id         = Column(String, ForeignKey("deals.id"), nullable=False, index=True)
    opener_id       = Column(String, ForeignKey("users.id"), nullable=False)
    issue_type      = Column(String, nullable=False)   # not_delivered|not_as_described|payment|fraud|other
    description     = Column(Text, nullable=False)
    zeno_verdict    = Column(Text, nullable=True)       # Zeno's full analysis text
    zac_code        = Column(String, nullable=True)     # e.g. ZAC-RELEASE-7K9P2X
    resolution_type = Column(String, nullable=True)     # release|refund|split
    status          = Column(Enum(DisputeStatus), default=DisputeStatus.open)
    created_at      = Column(DateTime, default=datetime.utcnow)
    resolved_at     = Column(DateTime, nullable=True)

class Review(Base):
    """Buyer review of a seller after a completed deal."""
    __tablename__ = "reviews"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id     = Column(String, ForeignKey("deals.id"), nullable=False, index=True)
    reviewer_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    seller_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    rating      = Column(Integer, nullable=False)          # 1-5 stars
    comment     = Column(Text, default="")
    created_at  = Column(DateTime, default=datetime.utcnow)


class FeaturedPayment(Base):
    """Tracks M-Pesa payments for listing boost (featured pin)."""
    __tablename__ = "featured_payments"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    listing_id          = Column(String, ForeignKey("listings.id"), nullable=False, index=True)
    plan                = Column(String, nullable=False)              # "week" | "month"
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    created_at          = Column(DateTime, default=datetime.utcnow)


class VerificationPayment(Base):
    """Tracks M-Pesa payments for seller badge purchase."""
    __tablename__ = "verification_payments"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    tier                = Column(String, nullable=False)              # "basic" | "gold"
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    created_at          = Column(DateTime, default=datetime.utcnow)


# ─── Init ────────────────────────────────────────────────────────────────────

async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Lightweight forward-compat: add new columns to existing rows-only DBs.
        # SQLite/Postgres ignore the IF NOT EXISTS path via try/except.
        from sqlalchemy import text
        migrations = [
            "ALTER TABLE users ADD COLUMN is_admin BOOLEAN DEFAULT 0 NOT NULL",
            "ALTER TABLE users ADD COLUMN last_seen DATETIME",
            "ALTER TABLE deals ADD COLUMN delivery_confirmed_at DATETIME",
            "ALTER TABLE deals ADD COLUMN released_at DATETIME",
            "ALTER TABLE deals ADD COLUMN refunded_at DATETIME",
        ]
        for stmt in migrations:
            try:
                await conn.execute(text(stmt))
            except Exception:
                pass  # column already exists
    print("✅ Database initialised")


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
