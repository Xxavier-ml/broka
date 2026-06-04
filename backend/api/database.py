"""
BROKA — Database Layer
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
    cancelled   = "cancelled"


# ─── Models ──────────────────────────────────────────────────────────────────

class User(Base):
    __tablename__ = "users"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name          = Column(String, nullable=False)
    email         = Column(String, unique=True, nullable=False, index=True)
    phone         = Column(String, nullable=True)
    password_hash = Column(String, nullable=False)
    lat           = Column(Float, nullable=True)
    lng           = Column(Float, nullable=True)
    rating        = Column(Float, default=5.0)
    completed_deals = Column(Integer, default=0)
    is_verified        = Column(Boolean, default=False)
    preferred_language = Column(String, default="english", nullable=True)
    created_at         = Column(DateTime, default=datetime.utcnow)

    listings      = relationship("Listing", back_populates="seller", foreign_keys="Listing.seller_id")


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
    # Media — stored as base64 or file paths/URLs
    # verified_photos: comma-separated list of base64 images or URLs (camera-only)
    verified_photos = Column(Text, nullable=True)
    # verified_video: single camera-captured video (base64 or URL, compulsory)
    verified_video  = Column(Text, nullable=True)
    # advert_video: optional promotional video (can be gallery-uploaded)
    advert_video    = Column(Text, nullable=True)
    created_at    = Column(DateTime, default=datetime.utcnow)

    seller        = relationship("User", back_populates="listings", foreign_keys=[seller_id])
    bids          = relationship("Bid", back_populates="listing")


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
    role           = Column(String, nullable=False)   # "seller" | "buyer" | "broker"
    # For broker messages: "buyer" means only the buyer sees it,
    # "seller" means only the seller sees it, None means both see it (legacy).
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

    listing     = relationship("Listing", back_populates="bids")


class Deal(Base):
    __tablename__ = "deals"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id   = Column(String, ForeignKey("listings.id"))
    seller_id    = Column(String, ForeignKey("users.id"))
    buyer_id     = Column(String, ForeignKey("users.id"))
    agreed_price = Column(Float, nullable=False)
    commission   = Column(Float, nullable=False)
    status       = Column(Enum(DealStatus), default=DealStatus.agreed)
    created_at   = Column(DateTime, default=datetime.utcnow)


# ─── Init ────────────────────────────────────────────────────────────────────

async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    print("✅ Database initialised")


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
