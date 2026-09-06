"""
BROKA - Calls Router
  • WebSocket relay  : /calls/ws/{room_id}   (WebRTC signaling)
  • Register token   : POST /calls/register-token
  • Initiate call    : POST /calls/initiate   (sends FCM to callee, issues room_id + call_token)
  • Call token       : GET  /calls/{room_id}/token   (exchange for callee, e.g. after an FCM tap)
  • Pending call     : GET  /calls/pending/{listing_id}   (callee poll fallback)
  • TURN credentials : GET  /calls/turn-credentials  (Cloudflare Realtime TURN)

Call SESSION/AUTHORIZATION state (who's on a call, what state it's in) lives
in api/core/call_state.py - Redis-backed when available, so it survives a
backend restart and (for that piece) works across multiple instances. The
live WebSocket connection OBJECTS in `_rooms` below are necessarily still
per-process - a socket object can't be serialized into Redis. That means
cross-instance signaling RELAY (caller on instance A reaching a callee on
instance B) isn't handled yet; today's Render deployment is single-instance,
so this doesn't bite in practice, but it's a known gap if that changes -
would need a Redis pub/sub relay layered on top of _rooms, not a bigger
change to call_state.py itself.
"""

import asyncio
import json
import os
import logging
import secrets
from typing import Dict, Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, Query, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, User, Listing, NegotiationMessage
from api.security import get_current_user, create_call_token, decode_call_token
from api.core import cloudflare_turn_client, call_state
from api.core.cloudflare_turn_client import CloudflareTurnError
from api.core.call_state import CallState
from api.core.rate_limit import (
    call_initiate_limiter, turn_credential_limiter,
    call_ws_connect_limiter, call_ws_preauth_limiter,
)

logger = logging.getLogger(__name__)
router = APIRouter()

# How long (seconds) to wait for ANY inbound WS activity before proactively
# pinging, and how many consecutive missed pings before the connection is
# treated as dead and closed (Phase 5 - previously absent entirely, so a
# radio-dropped mobile connection was only ever caught by the underlying
# TCP stack's own timeout, which can be minutes). ~3 x 15s gives a
# reconnect a real chance to land before the socket is given up on, while
# still being far faster than TCP's own dead-peer detection.
WS_HEARTBEAT_INTERVAL_SECONDS = 15
WS_HEARTBEAT_MAX_MISSED = 3

# ── In-memory WebSocket registry (per-process - see module docstring) ──────────
# Keyed by user_id (not an anonymous Set) so a reconnecting participant can
# be identified and safely replace their own stale/ghost socket, rather
# than the room being incorrectly treated as "full" by a raw peer count
# that can't tell a genuine second participant from the same user's old,
# not-yet-detected-as-dead connection.
_rooms: Dict[str, Dict[str, WebSocket]] = {}

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


async def _send_fcm(token: str, title: str, body: str, data: dict, *, data_only: bool = False) -> bool:
    """Send an FCM push notification. Returns True on success.

    data_only=True omits the FCM 'notification' block entirely. A
    'notification' block gets auto-displayed by the OS using generic
    system styling whenever the app isn't in the foreground - for an
    incoming call that means bypassing our own rich notification
    (full-screen intent, ringtone, Accept/Decline actions) in favor of a
    plain banner. Data-only messages always reach the app's own message
    handlers instead (foreground/background/terminated), which build the
    real incoming-call notification themselves. Every other caller of
    this function (reminders/nudges via workers.py) is unaffected by this
    parameter's default.
    """
    if not _get_fcm():
        logger.info("[calls] FCM not configured - skipping push")
        return False
    try:
        from firebase_admin import messaging
        msg = messaging.Message(
            notification=None if data_only else messaging.Notification(title=title, body=body),
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
    listing_id:   str
    caller_name:  str
    listing_name: Optional[str] = ""
    call_type:    str = "audio"   # "audio" | "video"
    # Required when the SELLER is calling (current user == listing.seller_id).
    # A listing can have many buyer negotiation threads, so unlike the
    # buyer-calls-seller direction (callee is always listing.seller_id -
    # unambiguous), the backend can't infer which buyer to ring on its own.
    # Ignored when the buyer is calling.
    callee_id: Optional[str] = None


class LogCallRequest(BaseModel):
    # Required (Section 16, V2 hardening): identifies the call via its
    # authoritative session - kept around for POST_CALL_GRACE_TTL_SECONDS
    # after the call ends specifically so this lookup works. Every
    # legitimate call has one (server-generated at /initiate).
    room_id: str
    # outcome: "completed" (was answered, regardless of how it ended) |
    #          "missed" (callee never answered) | "declined" (callee rejected)
    outcome:        str
    duration_secs:  Optional[int] = None
    call_type:      str = "audio"   # "audio" | "video" - legacy field, see docstring below
    # Legacy/fallback fields - IGNORED whenever the session lookup above
    # succeeds (the normal case), which derives these authoritatively
    # instead of trusting the client. Kept only so a not-yet-updated
    # client doesn't get a 422 for a missing field; never trusted for
    # anything on their own.
    listing_id: Optional[str] = None
    buyer_id:   Optional[str] = None
    caller_role: Optional[str] = None


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/turn-credentials")
async def get_turn_credentials(
    current: dict = Depends(get_current_user),
):
    """
    Short-lived Cloudflare Realtime TURN credentials for the ICE
    configuration WebRtcService passes into createPeerConnection() before
    starting a call. STUN-only ICE (the previous hardcoded-TURN setup)
    routinely fails silently on carrier-grade NAT - very common on Kenyan
    mobile data - which looks exactly like "call connects/rings but no
    audio flows"; a TURN relay is what still connects that case.

    No DB access needed - these credentials are Cloudflare-issued and
    ephemeral, never persisted on the BROKA side.
    """
    await turn_credential_limiter.check_and_record(current["id"])
    logger.info("[calls] TURN_CREDENTIAL_REQUESTED user=%s", current["id"])
    try:
        result = await cloudflare_turn_client.generate_ice_servers()
    except CloudflareTurnError as e:
        # Never leak Cloudflare's internal error detail (could include raw
        # response fragments) to the client - log it server-side only,
        # with the user id but no secrets. Neither the Cloudflare API
        # token nor any generated TURN credential ever reaches this log
        # line (see cloudflare_turn_client.py).
        logger.warning("[calls] TURN_CREDENTIAL_FAILED user=%s err=%s", current["id"], e)
        raise HTTPException(
            status_code=503,
            detail="Call relay is temporarily unavailable. Your call may still connect directly.",
        )

    logger.info(
        "[calls] TURN_CREDENTIAL_ISSUED user=%s expires_in=%s",
        current["id"], result["expires_in"],
    )
    return result


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
    current: dict         = Depends(get_current_user),
):
    """
    Called by whichever party is placing the call - buyer or seller -
    BEFORE navigating to the VoIP screen. Generates a fresh, unguessable
    room_id server-side (never client-supplied - a client-chosen id can't
    be trusted as the actual authorization boundary), creates the call
    session in call_state.py, and sends the callee an FCM push with enough
    data to open the VoIP screen as the callee.

    BUG FIX (forensic audit, 2026-09-03): this used to unconditionally
    resolve the callee as listing.seller_id and the caller as current user
    - correct for buyer-calls-seller, but it meant a SELLER trying to call
    a buyer back tripped the self-call guard below (current user ==
    listing.seller_id == the "callee" it had just resolved), so
    seller-initiated calls always failed with 400 and the buyer never saw
    anything. call_state.py's caller_id/callee_id were already generic
    (not buyer_id/seller_id) from the start, so only this resolution logic
    needed fixing, not the session store itself.

    Returns a short-lived call_token scoped to this room_id so the caller's
    WebSocket connection never needs their normal long-lived access token
    in the URL. The callee gets their own call_token from GET
    /calls/pending/{listing_id} (poll path) or GET /calls/{room_id}/token
    (e.g. answering straight from the FCM notification).
    """
    await call_initiate_limiter.check_and_record(current["id"])

    # Resolve the listing
    result  = await db.execute(select(Listing).where(Listing.id == payload.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    # Determine caller/callee explicitly - do NOT assume the seller is
    # always the callee (Phase 4). Whichever side owns the listing is
    # calling OUT; the other side is whoever they're negotiating with.
    if current["id"] == listing.seller_id:
        # Seller calling a specific buyer from one of this listing's
        # negotiation threads - can't be inferred from listing_id alone.
        if not payload.callee_id:
            raise HTTPException(status_code=400,
                                 detail="callee_id is required when the seller initiates a call")
        result = await db.execute(select(User).where(User.id == payload.callee_id))
        callee = result.scalar_one_or_none()
        if not callee:
            raise HTTPException(status_code=404, detail="Buyer not found")
        # A valid user id alone isn't enough authorization to ring them -
        # without this, any seller could call any registered user by
        # supplying an arbitrary callee_id, regardless of whether that
        # person has ever engaged with this listing (Phase 12: arbitrary
        # listing/buyer association). Require an actual prior message on
        # this listing/buyer thread, the same relationship check already
        # used to scope chat history elsewhere (see negotiate.py/media.py).
        thread_check = await db.execute(
            select(NegotiationMessage.id)
            .where(
                NegotiationMessage.listing_id == payload.listing_id,
                NegotiationMessage.buyer_id == payload.callee_id,
            )
            .limit(1)
        )
        if thread_check.scalar_one_or_none() is None:
            raise HTTPException(
                status_code=403,
                detail="No existing conversation with this buyer on this listing",
            )
        buyer_id_for_thread = callee.id
    else:
        # Buyer calling the listing's seller - the unambiguous, common case.
        result = await db.execute(select(User).where(User.id == listing.seller_id))
        callee = result.scalar_one_or_none()
        if not callee:
            raise HTTPException(status_code=404, detail="Seller not found")
        buyer_id_for_thread = current["id"]

    if callee.id == current["id"]:
        raise HTTPException(status_code=400, detail="You can't call yourself")

    room_id = secrets.token_urlsafe(16)  # unguessable - see call_state.py; matches create_refresh_token()'s sizing
    await call_state.create_session(
        room_id=room_id, caller_id=current["id"], callee_id=callee.id,
        listing_id=payload.listing_id, call_type=payload.call_type,
        caller_name=payload.caller_name,
    )
    await call_state.update_state(room_id, CallState.ringing)
    call_token = create_call_token(current["id"], room_id)

    logger.info(
        "[calls] CALL_INITIATED room=%s caller=%s callee=%s type=%s",
        room_id, current["id"], callee.id, payload.call_type,
    )
    logger.info("[calls] CALL_RINGING room=%s", room_id)

    if not callee.fcm_token:
        # Callee hasn't registered a token yet - still allow call (they'll see it if app is open)
        return {"status": "no_token", "message": "Callee has no push token yet",
                "room_id": room_id, "call_token": call_token}

    is_video = payload.call_type == "video"
    pushed = await _send_fcm(
        token=callee.fcm_token,
        title=f"{'📹' if is_video else '📞'} Incoming {'video ' if is_video else ''}call from {payload.caller_name}",
        body=f"About: {payload.listing_name or listing.name}",
        data={
            "type":        "incoming_call",
            "roomId":      room_id,
            "callerName":  payload.caller_name,
            "listingName": payload.listing_name or listing.name,
            "listingId":   payload.listing_id,
            "buyerId":     buyer_id_for_thread,  # explicit, not assumed - see fix note above
            "callType":    payload.call_type,
        },
        data_only=True,
    )
    return {"status": "sent" if pushed else "fcm_disabled",
            "room_id": room_id, "call_token": call_token}


@router.get("/{room_id}/token")
async def get_call_token(
    room_id: str,
    current: dict = Depends(get_current_user),
):
    """
    Exchanges the caller's normal (long-lived) auth for a call_token scoped
    to this one room_id - for the callee, who doesn't get one from
    /initiate (they didn't call it). Used when answering straight from the
    FCM-triggered incoming-call UI, without necessarily having gone through
    GET /pending/{listing_id} first (that path already returns a
    call_token directly, since it does this same check anyway).
    """
    session = await call_state.get_session(room_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Call not found or no longer active")
    if not session.is_participant(current["id"]):
        raise HTTPException(status_code=403, detail="You're not a participant on this call")
    if call_state.is_terminal(session.state):
        raise HTTPException(status_code=410, detail="This call has already ended")
    return {"call_token": create_call_token(current["id"], room_id)}


@router.post("/log-result")
async def log_call_result(
    payload: LogCallRequest,
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """
    Record the outcome of a finished call as a chat-thread card, visible to
    BOTH buyer and seller.

    SECURITY FIX (Section 16, V2 hardening): listing_id/buyer_id/
    caller_role used to come straight from the client with no
    verification - any authenticated user could have logged a fake call
    result for any listing/buyer pair, logged a call they weren't on, or
    logged a duplicate/conflicting result for a real one. Now: the
    authoritative call_state.py session (kept around briefly after the
    call ends specifically for this - see POST_CALL_GRACE_TTL_SECONDS) is
    looked up by room_id, the caller must actually be a participant, and
    listing_id/buyer_id/caller_role/call_type are ALL derived from that
    session rather than trusted from the request body.
    mark_result_logged() makes this idempotent - a second attempt for the
    same room_id is rejected outright, so a result can't be duplicated or
    overwritten once recorded.

    Also updates the authoritative call_state.py session to the matching
    terminal state (Section 14) - declined/missed/ended - which the state
    machine already supports (see call_state.py's transition table) but
    previously had no caller wiring it up for this specific path (a
    decline/missed call never joins the WebSocket, so nothing else in the
    system was transitioning the session for those two outcomes).
    """
    if payload.outcome not in ("completed", "missed", "declined", "cancelled"):
        raise HTTPException(status_code=400, detail="Invalid outcome")

    session = await call_state.get_session(payload.room_id)
    if session is None:
        raise HTTPException(
            status_code=404,
            detail="Call session not found - it may have expired, or its result may already be recorded",
        )
    if not session.is_participant(current["id"]):
        raise HTTPException(status_code=403, detail="You're not a participant on this call")

    if not await call_state.mark_result_logged(payload.room_id):
        raise HTTPException(status_code=409, detail="This call's result has already been recorded")

    result  = await db.execute(select(Listing).where(Listing.id == session.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    # Derived, not trusted - whichever of caller/callee ISN'T the listing's
    # seller is the buyer for chat-thread-scoping purposes, regardless of
    # which direction this particular call went (Section 13 symmetry).
    buyer_id    = session.callee_id if session.caller_id == listing.seller_id else session.caller_id
    caller_role = "seller" if session.caller_id == listing.seller_id else "buyer"
    actual_role = "seller" if current["id"] == listing.seller_id else "buyer"

    outcome_to_state = {
        "declined":  CallState.declined,
        "missed":    CallState.missed,
        # "cancelled" (caller hung up before the callee ever answered) is a
        # distinct outcome for call-history purposes, but reuses the
        # existing `missed` CallState - both are "ringing ended with no
        # answer" at the state-machine level; only who ended it differs,
        # which the outcome label alone already captures.
        "cancelled": CallState.missed,
        "completed": CallState.ended,
    }
    if not call_state.is_terminal(session.state):
        await call_state.update_state(payload.room_id, outcome_to_state[payload.outcome])

    if payload.outcome == "declined":
        # The caller's WS connection is very likely still open and waiting
        # (they navigate to the call screen and connect immediately on
        # placing the call) - nothing else tells them the callee declined
        # until their own ~45s ring timer gives up client-side. Notify
        # directly if we can reach them, reusing the existing 'hangup'
        # message type the client already handles - no new protocol needed.
        room = _rooms.get(payload.room_id)
        if room:
            caller_ws = room.get(session.caller_id)
            if caller_ws is not None:
                try:
                    await caller_ws.send_json({"type": "hangup", "reason": "declined"})
                except Exception:
                    pass

    # Taxonomy alignment (Section 33) - "missed" is what a client-side ring
    # timeout (VoipCallScreen's 45s timer / WebRtcService's own 30s
    # connect timeout) actually reports back as, so it's logged under the
    # same CALL_TIMEOUT event rather than a separate one.
    _event = {"declined": "CALL_DECLINED", "missed": "CALL_TIMEOUT",
              "cancelled": "CALL_CANCELLED", "completed": "CALL_ENDED"}
    logger.info("[calls] %s room=%s listing=%s buyer=%s outcome=%s",
                _event.get(payload.outcome, "CALL_RESULT"), payload.room_id, session.listing_id,
                buyer_id, payload.outcome)

    call_msg = NegotiationMessage(
        listing_id=session.listing_id,
        sender_id=current["id"],
        role=caller_role,
        recipient_role=None,
        content=payload.outcome,
        buyer_id=buyer_id,
        via_ai=False,
        msg_type="call",
        duration_secs=payload.duration_secs,
        call_type=session.call_type,
    )
    db.add(call_msg)
    await db.commit()
    await db.refresh(call_msg)

    # Broadcast so the other party sees it instantly if they're online.
    try:
        from api.routers.media import broadcast_text_message
        await broadcast_text_message(
            session.listing_id, buyer_id,
            call_msg, current["id"], actual_role == "seller",
        )
    except Exception:
        pass

    return {"status": "logged", "outcome": payload.outcome}


# ── WebSocket relay ────────────────────────────────────────────────────────────

@router.websocket("/ws/{room_id}")
async def call_signaling(
    websocket: WebSocket,
    room_id:   str,
    token:     str = Query(default=""),
):
    # This carries live WebRTC SDP/ICE signaling for a call - it must only
    # ever be joined by the two people actually on that call. `token` here
    # is a short-lived call_token (api/security.py's create_call_token,
    # scoped to exactly this room_id) - not the normal long-lived access
    # token, which used to sit in this URL where it could end up in proxy/
    # server access logs. Authorization is re-checked fresh against
    # call_state (Redis-backed) rather than falling back to "any valid JWT
    # gets in" if session state is momentarily missing - a call that can't
    # be verified should fail closed, not open.
    # IP-keyed, checked before token decode - see call_ws_preauth_limiter's
    # doc comment in rate_limit.py for why this can't wait until we have a
    # uid to key on.
    client_ip = websocket.client.host if websocket.client else "unknown"
    try:
        await call_ws_preauth_limiter.check_and_record(f"ip:{client_ip}")
    except HTTPException:
        await websocket.close(code=4008, reason="Too many connection attempts")
        return

    payload = decode_call_token(token)
    if not payload or payload.get("room_id") != room_id:
        await websocket.close(code=4001, reason="Unauthorized")
        return
    uid = payload["sub"]

    try:
        await call_ws_connect_limiter.check_and_record(uid)
    except HTTPException:
        await websocket.close(code=4008, reason="Too many connection attempts")
        return

    session = await call_state.get_session(room_id)
    if session is None:
        await websocket.close(code=4004, reason="Call no longer exists")
        return
    if not session.is_participant(uid):
        await websocket.close(code=4003, reason="Not a party to this call")
        return
    if call_state.is_terminal(session.state):
        await websocket.close(code=4004, reason="Call already ended")
        return

    await websocket.accept()

    room = _rooms.setdefault(room_id, {})

    stale = room.get(uid)
    if stale is not None:
        # Same user reconnecting - their previous socket is either already
        # dead (network drop) or about to be superseded by this one either
        # way. Close it best-effort and take over its slot, rather than
        # this new, legitimate connection getting rejected as "room full"
        # by a stale entry that hasn't been cleaned up yet.
        try:
            await stale.close(code=4009, reason="Replaced by a newer connection")
        except Exception:
            pass
        logger.info("[calls] GHOST_SOCKET_REPLACED room=%s user=%s", room_id, uid)
    elif len(room) >= 2:
        # Room already has two DIFFERENT participants - genuinely full.
        await websocket.send_json({"type": "busy", "message": "Room is full"})
        await websocket.close()
        return

    room[uid] = websocket
    await call_state.set_participant_connected(room_id, uid, True)
    if uid == session.callee_id:
        # Only the callee's join means "accepted" - the caller's own join
        # (they're always first) just means they're waiting.
        await call_state.update_state(room_id, CallState.accepted)
        logger.info("[calls] CALL_ACCEPTED room=%s user=%s", room_id, uid)
    logger.info("[calls] user=%s joined room=%s peers=%d", uid, room_id, len(room))

    # Notify both peers when room is ready for SDP exchange
    if len(room) == 2:
        await call_state.update_state(room_id, CallState.connecting)
        logger.info("[calls] WEBRTC_CONNECTING room=%s", room_id)
        for peer in list(room.values()):
            try:
                await peer.send_json({"type": "ready", "room_id": room_id})
            except Exception:
                pass

    try:
        missed_heartbeats = 0
        while True:
            try:
                raw = await asyncio.wait_for(
                    websocket.receive_text(),
                    timeout=WS_HEARTBEAT_INTERVAL_SECONDS,
                )
            except asyncio.TimeoutError:
                # No activity (signaling or a prior pong) for a full
                # interval - ping and keep counting; only give up after
                # several in a row so one slow beat on a loaded mobile
                # network doesn't drop a perfectly healthy call.
                missed_heartbeats += 1
                if missed_heartbeats > WS_HEARTBEAT_MAX_MISSED:
                    logger.info("[calls] HEARTBEAT_TIMEOUT room=%s user=%s", room_id, uid)
                    try:
                        await websocket.close(code=4000, reason="Heartbeat timeout")
                    except Exception:
                        pass
                    break
                try:
                    await websocket.send_json({"type": "ping"})
                except Exception:
                    break
                continue
            missed_heartbeats = 0

            try:
                msg = json.loads(raw)
                if not isinstance(msg, dict):
                    raise ValueError("signaling message must be a JSON object")
            except (ValueError, TypeError) as e:
                # Reject just this one message and keep the connection -
                # a malformed frame from a buggy/adversarial client
                # shouldn't take down the whole signaling loop (Phase 5).
                logger.warning("[calls] MALFORMED_MESSAGE room=%s user=%s err=%s", room_id, uid, e)
                continue
            msg_type = msg.get("type")

            if msg_type == "pong":
                # Answers our own heartbeat ping above - nothing to relay,
                # already counted as activity via missed_heartbeats=0 above.
                continue

            # Client-reported WebRTC peer-connection state (Sections 5, 33) -
            # only the client can observe this about its own RTCPeerConnection,
            # so it's the one channel where we trust client-asserted state.
            # Deliberately NOT relayed to the other peer (each side already
            # gets this from its own onConnectionState callback) and
            # deliberately restricted to exactly these 3 values - the client
            # can't use this to claim e.g. "accepted" or "ended", which stay
            # server-authoritative (driven by room membership/hangup above).
            if msg_type == "state":
                reported = msg.get("state")
                if reported in ("connected", "disconnected", "failed"):
                    await call_state.update_state(room_id, CallState(reported))
                    logger.info("[calls] WEBRTC_%s room=%s user=%s",
                                reported.upper(), room_id, uid)
                continue

            for peer_uid, peer in list(room.items()):
                if peer_uid == uid:
                    continue
                try:
                    await peer.send_text(raw)
                except Exception:
                    pass

            if msg_type == "hangup":
                break

    except WebSocketDisconnect:
        logger.info("[calls] user=%s disconnected from room=%s", uid, room_id)
    finally:
        # Only remove OUR OWN entry, and only if it still points to THIS
        # specific connection - a ghost socket being closed above (see the
        # admission block) wakes up its own handler here, and by then a
        # NEWER connection may have already taken over room[uid]. Blindly
        # popping by key would delete the newer socket out from under the
        # call that's actually still active.
        if room.get(uid) is websocket:
            del room[uid]
            await call_state.set_participant_connected(room_id, uid, False)
        if not room:
            _rooms.pop(room_id, None)
            current_session = await call_state.get_session(room_id)
            if current_session and not call_state.is_terminal(current_session.state):
                await call_state.update_state(room_id, CallState.ended)
            logger.info("[calls] CALL_ENDED room=%s", room_id)
            # Deliberately NOT calling end_session() (immediate delete)
            # here - update_state() above already shortened this session's
            # TTL to POST_CALL_GRACE_TTL_SECONDS as soon as it hit a
            # terminal state, which gives POST /calls/log-result (called
            # by the client right after hangup) a real window to look the
            # session up and derive authoritative caller/callee/listing
            # info instead of trusting client-supplied values (Section 16).
            # It'll expire on its own shortly either way.
        else:
            # One side dropped but the other is still here - reflect that
            # distinctly from a mutual hangup; the remaining peer's own
            # disconnect (which follows shortly, once its client reacts to
            # this "hangup" notice) is what finally reaches `ended` above.
            # Skip this entirely if we're the STALE socket being replaced
            # (room.get(uid) is not websocket, i.e. we already lost the
            # check above) - the call is still healthy, just handed off to
            # a newer connection, not actually disconnected.
            if room.get(uid) is None or room.get(uid) is websocket:
                current_session = await call_state.get_session(room_id)
                if current_session and not call_state.is_terminal(current_session.state):
                    await call_state.update_state(room_id, CallState.disconnected)
                    logger.info("[calls] WEBRTC_DISCONNECTED room=%s user=%s", room_id, uid)
                for peer in list(room.values()):
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
    current: dict = Depends(get_current_user),
):
    """
    Seller polls this to detect incoming calls. call_state.get_pending_call
    does an O(1) lookup keyed by (listing_id, this user's id) rather than
    scanning every active call - this is called repeatedly while a call
    rings, so it needs to stay cheap. Also issues the callee's call_token
    directly here, since this path already does the full authorization
    check anyway - saves a round trip to GET /{room_id}/token.
    """
    session = await call_state.get_pending_call(listing_id, current["id"])
    if session is None:
        return {"has_call": False}

    # Caller polling their own listing's pending-call state (e.g. a seller
    # who is also testing their own listing) must never see their own
    # outgoing call reflected back as "incoming".
    if session.caller_id == current["id"]:
        return {"has_call": False}

    return {
        "has_call":    True,
        "room_id":     session.room_id,
        "caller_name": session.caller_name,
        "caller_id":   session.caller_id,  # explicit, replaces parsing buyer_id out of room_id client-side
        "call_type":   session.call_type,
        "call_token":  create_call_token(current["id"], session.room_id),
    }
