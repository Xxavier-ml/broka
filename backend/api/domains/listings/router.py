"""Listings Router v3.0"""
from __future__ import annotations

import json
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import ListingService

router = APIRouter()


class ListingIn(BaseModel):
    name: str
    category: str
    subcategory_id: Optional[str] = None
    condition: Optional[str] = None  # "new" | "used" | "refurbished"
    attributes: Optional[Dict[str, Any]] = None  # dynamic category fields, e.g. {"make": "Toyota"}
    price: float
    lat: float
    lng: float
    description: Optional[str] = None
    location_name: Optional[str] = None
    # Structured location (2026-08-29). location_county/location_subcounty
    # are the new 3-part location step's real inputs; location_country
    # isn't sent by the client at all right now (fixed to Kenya - see
    # sell_location_screen.dart), so it's not exposed here. location_name
    # above is kept for backward compatibility - ListingService derives it
    # from county+subcounty when they're present rather than trusting a
    # client-sent value, so existing readers (search, negotiate prompts,
    # buy_agent matching...) keep seeing a normal display string either way.
    location_county: Optional[str] = None
    location_subcounty: Optional[str] = None
    listing_type: str = "direct"
    verified_photos: Optional[str] = None
    verified_video: Optional[str] = None
    advert_video: Optional[str] = None
    target_bidders: Optional[int] = None
    auction_date: Optional[str] = None
    reserve_price: Optional[float] = None
    # AI Showcase/Cover Image (2026-08-29). Optional - set only when the
    # wizard's Showcase step produced one (gallery pick or an AI preview
    # the seller explicitly chose "Use This Image" on client-side; see
    # SellWizardData.showcaseImageDataUri). Both must be given together or
    # not at all - validated in create_listing, not here, so the error can
    # reference both fields by name in one message.
    showcase_image_url: Optional[str] = None
    showcase_image_source: Optional[str] = None  # "gallery" | "ai"


class InterestIn(BaseModel):
    offer_price: Optional[float] = None


@router.get("/stats")
async def get_stats(db: AsyncSession = Depends(get_db)):
    svc = ListingService(db)
    return await svc.get_stats()


@router.get("/")
async def list_listings(
    category: Optional[str] = None,
    category_id: Optional[str] = None,
    subcategory_id: Optional[str] = None,
    condition: Optional[str] = None,
    listing_type: Optional[str] = None,
    seller_id: Optional[str] = None,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    max_km: Optional[float] = None,
    min_price: Optional[float] = None,
    max_price: Optional[float] = None,
    search: Optional[str] = None,
    location: Optional[str] = None,
    attributes: Optional[str] = None,  # JSON-encoded dict, e.g. '{"brand":"Samsung"}'
    sort: Optional[str] = None,
    with_total: bool = False,
    limit: int = 20,
    offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    parsed_attributes = None
    if attributes:
        try:
            parsed_attributes = json.loads(attributes)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="attributes must be valid JSON")
    return await svc.list_listings(
        category=category,
        category_id=category_id,
        subcategory_id=subcategory_id,
        condition=condition,
        listing_type=listing_type,
        seller_id=seller_id,
        viewer_lat=lat,
        viewer_lng=lng,
        max_km=max_km,
        min_price=min_price,
        max_price=max_price,
        search=search,
        location=location,
        attributes=parsed_attributes,
        sort=sort,
        with_total=with_total,
        limit=limit,
        offset=offset,
    )


@router.post("/", status_code=201)
async def create_listing(
    body: ListingIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.create_listing(current_user["id"], body.model_dump())


@router.get("/seller/{seller_id}/revenue")
async def get_seller_revenue(
    seller_id: str,
    period: str = "week",
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Real revenue-over-time for the seller dashboard chart, aggregated
    from actually-completed (released) deals - a seller may only see their
    own revenue breakdown."""
    from fastapi import HTTPException
    if current_user["id"] != seller_id:
        raise HTTPException(status_code=403, detail="Not authorized for this seller's revenue")
    svc = ListingService(db)
    return await svc.get_seller_revenue(seller_id, period if period in ("week", "month") else "week")


@router.get("/{listing_id}")
async def get_listing(listing_id: str, db: AsyncSession = Depends(get_db)):
    svc = ListingService(db)
    return await svc.get_listing(listing_id)


@router.post("/{listing_id}/interest")
async def express_interest(
    listing_id: str,
    body: InterestIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.express_interest(listing_id, current_user["id"], body.offer_price)


@router.get("/{listing_id}/matches")
async def get_matches(
    listing_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.get_matches(listing_id)
