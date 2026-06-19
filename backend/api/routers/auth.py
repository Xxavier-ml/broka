"""BROKA - Auth Router: register, login, user search, profile & photo upload."""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, or_
import math

from api.database import get_db, User
from api.schemas import RegisterRequest, LoginRequest, UpdateProfileRequest
from api.security import hash_password, verify_password, create_access_token, get_current_user
from datetime import datetime as _dt

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
        nickname=payload.nickname,
        email=payload.email,
        phone=payload.phone,
        password_hash=hash_password(payload.password),
        lat=payload.lat,
        lng=payload.lng,
        profile_photo=payload.profile_photo,
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
        "nickname": user.nickname,
        "email": user.email,
        "profile_photo": user.profile_photo,
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
        "nickname": user.nickname,
        "email": user.email,
        "lat": user.lat,
        "lng": user.lng,
        "profile_photo": user.profile_photo,
    }


@router.get("/me")
async def get_me(current_user=Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    from api.database import Listing, Deal, ListingStatus
    from sqlalchemy import func

    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    listing_count_result = await db.execute(
        select(func.count(Listing.id)).where(
            Listing.seller_id == user.id,
            Listing.status == ListingStatus.active,
        )
    )
    listing_count = listing_count_result.scalar() or 0

    volume_result = await db.execute(
        select(func.sum(Deal.agreed_price)).where(Deal.seller_id == user.id)
    )
    volume = volume_result.scalar() or 0.0

    return {
        "id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "email": user.email,
        "phone": user.phone,
        "lat": user.lat,
        "lng": user.lng,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "listing_count": listing_count,
        "volume_traded": volume,
        "is_verified": user.is_verified,
        "profile_photo": user.profile_photo,
        "created_at": user.created_at.isoformat(),
    }


@router.patch("/profile")
async def update_profile(
    payload: UpdateProfileRequest,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update nickname and/or profile selfie."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if payload.nickname is not None:
        user.nickname = payload.nickname
    if payload.profile_photo is not None:
        user.profile_photo = payload.profile_photo
    await db.commit()
    return {"status": "ok", "nickname": user.nickname}


@router.get("/search")
async def search_users(
    q: str = Query(min_length=1, max_length=80),
    lat: float = Query(default=None),
    lng: float = Query(default=None),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(User).where(
            User.id != current_user["id"],
            or_(
                User.name.ilike(f"%{q}%"),
                User.email.ilike(f"%{q}%"),
                User.nickname.ilike(f"%{q}%"),
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
            "nickname": u.nickname,
            "rating": u.rating,
            "completed_deals": u.completed_deals,
            "is_verified": u.is_verified,
            # Only expose location if the user opted in
            "distance_km": _dist(u) if getattr(u, "location_visible", True) else None,
            "location_name": _approx_location(u.lat, u.lng) if getattr(u, "location_visible", True) else None,
            "profile_photo": u.profile_photo,
            "member_since": u.created_at.strftime("%b %Y") if u.created_at else None,
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
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    distance_km = None
    if lat and lng and user.lat and user.lng:
        distance_km = round(_haversine_km(lat, lng, user.lat, user.lng), 1)

    loc_visible = getattr(user, "location_visible", True)

    # Online status: last_seen within 5 minutes = online
    is_online = False
    last_seen_str = "Recently active"
    if user.last_seen:
        delta = _dt.utcnow() - user.last_seen
        secs = int(delta.total_seconds())
        is_online = secs < 300
        if secs < 60:      last_seen_str = "Active now"
        elif secs < 3600:  last_seen_str = f"Active {secs//60}m ago"
        elif secs < 86400: last_seen_str = f"Active {secs//3600}h ago"
        else:              last_seen_str = f"Active {secs//86400}d ago"

    return {
        "id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "is_verified": user.is_verified,
        "location_name": _approx_location(user.lat, user.lng) if loc_visible else None,
        "distance_km": distance_km if loc_visible else None,
        "location_visible": loc_visible,
        "profile_photo": user.profile_photo,
        "biometric_enrolled": getattr(user, "biometric_enrolled", None),
        "member_since": user.created_at.strftime("%b %Y") if user.created_at else None,
        "is_online": is_online,
        "last_seen": last_seen_str,
    }


@router.patch("/location")
async def update_location(
    lat: float = Query(...),
    lng: float = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
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


@router.patch("/location-visibility")
async def toggle_location_visibility(
    visible: bool = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Toggle whether the user's location appears on their public profile."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.location_visible = visible
    await db.commit()
    return {"status": "ok", "location_visible": visible}


@router.patch("/biometric-enroll")
async def enroll_biometric(
    biometric_type: str = Query(...),  # 'fingerprint' | 'face' | 'none'
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Record that the user has enrolled a specific biometric type for BROKA."""
    allowed = ["fingerprint", "face", "none"]
    if biometric_type not in allowed:
        raise HTTPException(status_code=400,
            detail=f"biometric_type must be one of: {', '.join(allowed)}")
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.biometric_enrolled = biometric_type if biometric_type != "none" else None
    await db.commit()
    return {"status": "ok", "biometric_enrolled": user.biometric_enrolled}

@router.post("/heartbeat")
async def heartbeat(
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Called every ~60s by the app to update last_seen timestamp."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user   = result.scalar_one_or_none()
    if user:
        user.last_seen = _dt.utcnow()
        await db.commit()
    return {"ok": True}

