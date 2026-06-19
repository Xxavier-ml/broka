"""
BROKA - Calls Router
  • WebSocket relay  : /calls/ws/{room_id}   (WebRTC signaling)
  • Register token   : POST /calls/register-token
  • Initiate call    : POST /calls/initiate   (sends FCM to callee)
"""

import json
import os
import logging
from typing import Dict, Set, Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, Query, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, User, Listing
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

# ── In-memory room registry ────────────────────────────────────────────────────
_rooms: Dict[str, Set[WebSocket]] = {}

# ── Firebase Admin (optional - gracefully disabled if not configured) ──────────
_fcm_app = None

def _get_fcm():
    """Lazily initialize Firebase Admin from env var."""
    global _fcm_app
    if _fcm_app is not None:
        return _fcm_app
    raw = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not raw:
        return None
    try:
        import json as _json
        import firebase_admin
        from firebase_admin import credentials
        if not firebase_admin._apps:
            cred       = credentials.Certificate(_json.loads(raw))
            _fcm_app   = firebase_admin.initialize_app(cred)
        else:
            _fcm_app   = firebase_admin.get_app()
        logger.info("[calls] Firebase Admin initialised")
    except Exception as e:
        logger.warning(f"[calls] Firebase Admin init failed: {e}")
        _fcm_app = None
    return _fcm_app


async def _send_fcm(token: str, title: str, body: str, data: dict) -> bool:
    """Send an FCM push notification. Returns True on success."""
    if not _get_fcm():
        logger.info("[calls] FCM not configured - skipping push")
        return False
    try:
        from firebase_admin import messaging
        msg = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in data.items()},
            token=token,
            android=messaging.AndroidConfig(priority="high"),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(
                        content_available=True,
                        sound="default",
                    )
                )
            ),
        )
        messaging.send(msg)
        return True
    except Exception as e:
        logger.warning(f"[calls] FCM send failed: {e}")
        return False


# ── Schemas ───────────────────────────────────────────────────────────────────

class RegisterTokenRequest(BaseModel):
    fcm_token: str

class InitiateCallRequest(BaseModel):
    room_id:      str
    listing_id:   str
    caller_name:  str
    listing_name: Optional[str] = ""


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/register-token")
async def register_token(
    payload: RegisterTokenRequest,
    db:      AsyncSession = Depends(get_db),
    current: User         = Depends(get_current_user),
):
    """Store the caller's FCM token so they can receive incoming call alerts."""
    current.fcm_token = payload.fcm_token
    await db.commit()
    return {"status": "ok"}


@router.post("/initiate")
async def initiate_call(
    payload: InitiateCallRequest,
    db:      AsyncSession = Depends(get_db),
    current: User         = Depends(get_current_user),
):
    """
    Called by the buyer BEFORE navigating to the VoIP screen.
    Looks up the listing's seller and sends them an FCM push notification
    with enough data to open the VoIP screen as the callee.
    """
    # Resolve the listing
    result  = await db.execute(select(Listing).where(Listing.id == payload.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    # Get the seller
    result = await db.execute(select(User).where(User.id == listing.seller_id))
    seller = result.scalar_one_or_none()
    if not seller:
        raise HTTPException(status_code=404, detail="Seller not found")

    if not seller.fcm_token:
        # Seller hasn't registered a token yet - still allow call (they'll see it if app is open)
        return {"status": "no_token", "message": "Seller has no push token yet"}

    pushed = await _send_fcm(
        token=seller.fcm_token,
        title=f"📞 Incoming call from {payload.caller_name}",
        body=f"About: {payload.listing_name or listing.name}",
        data={
            "type":        "incoming_call",
            "roomId":      payload.room_id,
            "callerName":  payload.caller_name,
            "listingName": payload.listing_name or listing.name,
            "listingId":   payload.listing_id,
        },
    )
    return {"status": "sent" if pushed else "fcm_disabled"}


# ── WebSocket relay ────────────────────────────────────────────────────────────

@router.websocket("/ws/{room_id}")
async def call_signaling(
    websocket: WebSocket,
    room_id:   str,
    token:     str = Query(default=""),
    user_id:   str = Query(default="anonymous"),
):
    await websocket.accept()

    room = _rooms.setdefault(room_id, set())

    if len(room) >= 2:
        await websocket.send_json({"type": "busy", "message": "Room is full"})
        await websocket.close()
        return

    room.add(websocket)
    logger.info(f"[calls] {user_id} joined room={room_id}  peers={len(room)}")

    # Notify both peers when room is ready for SDP exchange
    if len(room) == 2:
        for peer in list(room):
            try:
                await peer.send_json({"type": "ready", "room_id": room_id})
            except Exception:
                pass

    try:
        while True:
            raw = await websocket.receive_text()
            msg = json.loads(raw)

            others = room - {websocket}
            for peer in list(others):
                try:
                    await peer.send_text(raw)
                except Exception:
                    pass

            if msg.get("type") == "hangup":
                break

    except WebSocketDisconnect:
        logger.info(f"[calls] {user_id} disconnected from room={room_id}")
    finally:
        room.discard(websocket)
        if not room:
            _rooms.pop(room_id, None)
        else:
            for peer in list(room):
                try:
                    await peer.send_json({
                        "type": "hangup",
                        "reason": "peer_disconnected",
                    })
                except Exception:
                    pass

@router.get("/pending/{listing_id}")
async def get_pending_call(
    listing_id: str,
    db: AsyncSession = Depends(get_db),
    current: dict = Depends(get_current_user),
):
    """
    Seller polls this to detect incoming calls.
    Returns active room_id if a call is waiting for this listing.
    """
    # Find any active room for this listing
    for room_id, sockets in _rooms.items():
        if listing_id in room_id and len(sockets) == 1:
            # One peer is waiting in the room - this is an incoming call
            caller_name = "Buyer"
            return {
                "has_call":    True,
                "room_id":     room_id,
                "caller_name": caller_name,
            }
    return {"has_call": False}
