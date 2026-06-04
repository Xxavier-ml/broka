"""BROKA — Auth Router: register, login, user search & profile."""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, or_
import math

from api.database import get_db, User
from api.schemas import RegisterRequest, LoginRequest
from api.security import hash_password, verify_password, create_access_token, get_current_user

router = APIRouter()


def _haversine_km(lat1, lng1, lat2, lng2):
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
    return R * 2 * math.asin(math.sqrt(a))


@router.post("/register", status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == payload.email))
    if result.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Email already registered")

    user = User(
        name=payload.name,
        email=payload.email,
        phone=payload.phone,
        password_hash=hash_password(payload.password),
        lat=payload.lat,
        lng=payload.lng,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    token = create_access_token({"sub": user.id})
    return {
        "access_token": token,
        "token_type": "bearer",
        "user_id": user.id,
        "name": user.name,
        "email": user.email,
    }


@router.post("/login")
async def login(payload: LoginRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == payload.email))
    user = result.scalar_one_or_none()

    if not user or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = create_access_token({"sub": user.id})
    return {
        "access_token": token,
        "token_type": "bearer",
        "user_id": user.id,
        "name": user.name,
        "email": user.email,
        "lat": user.lat,
        "lng": user.lng,
    }


@router.get("/me")
async def get_me(current_user=Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    from api.database import Listing, Deal, ListingStatus
    from sqlalchemy import func

    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Real listing count
    listing_count_result = await db.execute(
        select(func.count(Listing.id)).where(
            Listing.seller_id == user.id,
            Listing.status == ListingStatus.active,
        )
    )
    listing_count = listing_count_result.scalar() or 0

    # Real volume traded (as seller)
    volume_result = await db.execute(
        select(func.sum(Deal.agreed_price)).where(Deal.seller_id == user.id)
    )
    volume = volume_result.scalar() or 0.0

    return {
        "id": user.id,
        "name": user.name,
        "email": user.email,
        "phone": user.phone,
        "lat": user.lat,
        "lng": user.lng,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "listing_count": listing_count,
        "volume_traded": volume,
        "is_verified": user.is_verified,
        "created_at": user.created_at.isoformat(),
    }


@router.get("/search")
async def search_users(
    q: str = Query(min_length=1, max_length=80),
    lat: float = Query(default=None),
    lng: float = Query(default=None),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Search users by name or email — for finding trading partners."""
    result = await db.execute(
        select(User).where(
            User.id != current_user["id"],
            or_(
                User.name.ilike(f"%{q}%"),
                User.email.ilike(f"%{q}%"),
            )
        ).limit(20)
    )
    users = result.scalars().all()

    def _dist(u):
        if lat and lng and u.lat and u.lng:
            return round(_haversine_km(lat, lng, u.lat, u.lng), 1)
        return None

    return [
        {
            "id": u.id,
            "name": u.name,
            "email": u.email,
            "rating": u.rating,
            "completed_deals": u.completed_deals,
            "is_verified": u.is_verified,
            "lat": u.lat,
            "lng": u.lng,
            "distance_km": _dist(u),
        }
        for u in users
    ]


@router.get("/user/{user_id}")
async def get_user_profile(
    user_id: str,
    lat: float = Query(default=None),
    lng: float = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    """Get any user's public profile."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    distance_km = None
    if lat and lng and user.lat and user.lng:
        distance_km = round(_haversine_km(lat, lng, user.lat, user.lng), 1)

    return {
        "id": user.id,
        "name": user.name,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "is_verified": user.is_verified,
        "location_name": _approx_location(user.lat, user.lng),
        "distance_km": distance_km,
    }


@router.patch("/location")
async def update_location(
    lat: float = Query(...),
    lng: float = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update the current user's GPS coordinates."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.lat = lat
    user.lng = lng
    await db.commit()
    return {"status": "ok", "lat": lat, "lng": lng}


def _approx_location(lat, lng):
    if not lat or not lng:
        return "Kenya"
    if -1.5 < lat < -1.1 and 36.6 < lng < 37.1: return "Nairobi, Kenya"
    if -0.2 < lat < 0.2  and 34.6 < lng < 35.0: return "Kisumu, Kenya"
    if  0.0 < lat < 0.6  and 35.0 < lng < 35.5: return "Eldoret, Kenya"
    if -4.2 < lat < -3.8 and 39.5 < lng < 40.0: return "Mombasa, Kenya"
    return "Kenya"


@router.patch("/language")
async def update_language(
    language: str = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update the current user's preferred language."""
    supported = ["english", "swahili", "luo", "kikuyu", "luganda", "sheng"]
    if language.lower() not in supported:
        raise HTTPException(status_code=400,
            detail=f"Unsupported language. Choose from: {', '.join(supported)}")
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.preferred_language = language.lower()
    await db.commit()
    return {"status": "ok", "language": language.lower()}
