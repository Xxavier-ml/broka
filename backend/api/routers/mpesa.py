"""
BROKA - M-Pesa Router (Daraja API v2 - M-Pesa Express / STK Push)

ENV VARS REQUIRED (set in Render dashboard):
  MPESA_CONSUMER_KEY    - from Safaricom Daraja portal (BROKA sandbox app)
  MPESA_CONSUMER_SECRET - from Safaricom Daraja portal (BROKA sandbox app)
  MPESA_SHORTCODE       - 174379 (sandbox default)
  MPESA_PASSKEY         - bfb279f9aa9bdbcf158e97dd71a467cd2e0c893059b10f78e6b72ada1ed2c919
  MPESA_CALLBACK_URL    - https://broka-dbjd.onrender.com/mpesa/callback
  MPESA_ENV             - sandbox | production
"""

import os
import base64
import httpx
import logging
from datetime import datetime, timezone, timedelta
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel

from api.database import get_db, Deal, DealStatus, User, MpesaTransaction, MpesaStatus
from api.security import get_current_user, verify_password
from api.core.events import publish, EscrowFunded, MpesaCallbackReceived

logger = logging.getLogger(__name__)
router = APIRouter()

# ── Config ────────────────────────────────────────────────────────────────────

MPESA_ENV      = os.getenv("MPESA_ENV", "sandbox")
CONSUMER_KEY   = os.getenv("MPESA_CONSUMER_KEY", "")
CONSUMER_SECRET= os.getenv("MPESA_CONSUMER_SECRET", "")
SHORTCODE      = os.getenv("MPESA_SHORTCODE", "174379")
PASSKEY        = os.getenv("MPESA_PASSKEY", "")

# Safaricom's callback protocol has no way to sign/verify the webhook body,
# so the callback endpoint is authenticated by a secret path segment instead
# (this is the standard mitigation for Daraja integrations). Without this,
# ANYONE who knows/discovers the fixed `/mpesa/callback` URL - including a
# buyer replaying their own CheckoutRequestID from a legitimate /stk-push
# call they made themselves - could POST a fabricated "payment succeeded"
# callback and get a deal marked `paid` with no real money having moved.
#
# If MPESA_CALLBACK_SECRET is set, the callback URL Safaricom is told to use
# defaults to the protected `/mpesa/callback/{secret}` path; the old
# unauthenticated `/mpesa/callback` route is kept working (unless you have
# already registered a custom MPESA_CALLBACK_URL, in which case that exact
# value is always respected) so nothing breaks for existing deployments that
# haven't set the secret yet. See mpesa_callback()/mpesa_callback_secured()
# below.
CALLBACK_SECRET = os.getenv("MPESA_CALLBACK_SECRET", "")
_DEFAULT_CALLBACK_BASE = "https://broka-dbjd.onrender.com/mpesa/callback"
if os.getenv("MPESA_CALLBACK_URL"):
    # Deployer set this explicitly - always respect it verbatim.
    CALLBACK_URL = os.getenv("MPESA_CALLBACK_URL", _DEFAULT_CALLBACK_BASE)
elif CALLBACK_SECRET:
    CALLBACK_URL = f"{_DEFAULT_CALLBACK_BASE}/{CALLBACK_SECRET}"
else:
    CALLBACK_URL = _DEFAULT_CALLBACK_BASE

BASE_URL  = "https://api.safaricom.co.ke" if MPESA_ENV == "production" else "https://sandbox.safaricom.co.ke"
OAUTH_URL = f"{BASE_URL}/oauth/v1/generate?grant_type=client_credentials"
STK_URL   = f"{BASE_URL}/mpesa/stkpush/v1/processrequest"
QUERY_URL = f"{BASE_URL}/mpesa/stkpushquery/v1/query"


# ── Helpers ───────────────────────────────────────────────────────────────────

async def _get_access_token() -> str:
    credentials = base64.b64encode(f"{CONSUMER_KEY}:{CONSUMER_SECRET}".encode()).decode()
    logger.info("M-Pesa OAuth attempt - ENV=%s SHORTCODE=%s KEY_PREFIX=%s URL=%s",
                MPESA_ENV, SHORTCODE, CONSUMER_KEY[:6] if CONSUMER_KEY else "MISSING", OAUTH_URL)
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(OAUTH_URL, headers={"Authorization": f"Basic {credentials}"})
    logger.info("M-Pesa OAuth response - status=%s body=%s", resp.status_code, resp.text[:300])
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"M-Pesa OAuth failed: {resp.text}")
    return resp.json()["access_token"]


def _generate_password() -> tuple[str, str]:
    # Daraja requires the timestamp in Nairobi local time (EAT, UTC+3).
    # Servers run UTC, so derive EAT explicitly instead of using datetime.now().
    nairobi = datetime.now(timezone.utc) + timedelta(hours=3)
    timestamp = nairobi.strftime("%Y%m%d%H%M%S")
    raw       = f"{SHORTCODE}{PASSKEY}{timestamp}"
    password  = base64.b64encode(raw.encode()).decode()
    return timestamp, password


def _normalize_phone(phone: str) -> str:
    """Convert 07XXXXXXXX → 2547XXXXXXXX"""
    phone = phone.strip().replace(" ", "").replace("-", "")
    if phone.startswith("0"):
        phone = "254" + phone[1:]
    elif phone.startswith("+"):
        phone = phone[1:]
    return phone


# ── Schemas ───────────────────────────────────────────────────────────────────

class StkPushRequest(BaseModel):
    deal_id:      str
    phone_number: str   # 07XX or 2547XX
    password:     str   # user's BROKA account password for authorization


class StkQueryRequest(BaseModel):
    checkout_request_id: str


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/stk-push")
async def initiate_stk_push(
    data: StkPushRequest,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Trigger M-Pesa STK push to buyer's phone for the BROKA commission.
    Requires the user's BROKA password as a second-factor authorization.
    Only the buyer of the deal may initiate.
    """
    # 1. Verify user's password before doing anything
    user_result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = user_result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not verify_password(data.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Incorrect password")

    # 2. Load and validate deal
    deal_result = await db.execute(select(Deal).where(Deal.id == data.deal_id))
    deal = deal_result.scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    if deal.buyer_id != current_user["id"]:
        raise HTTPException(status_code=403, detail="Only the buyer can pay the commission")
    if deal.status not in (DealStatus.agreed,):
        raise HTTPException(status_code=400, detail="Deal is not in 'agreed' state")

    # 3. Calculate amount (whole KES, minimum 1)
    amount = max(1, int(round(deal.commission)))
    phone  = _normalize_phone(data.phone_number)

    # 4. Get Safaricom access token
    token = await _get_access_token()
    timestamp, password = _generate_password()

    # 5. STK Push payload
    payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          password,
        "Timestamp":         timestamp,
        "TransactionType":   "CustomerPayBillOnline",
        "Amount":            amount,
        "PartyA":            phone,
        "PartyB":            SHORTCODE,
        "PhoneNumber":       phone,
        "CallBackURL":       CALLBACK_URL,
        "AccountReference":  f"BROKA-{deal.id[:8].upper()}",
        "TransactionDesc":   f"BROKA commission for deal {deal.id[:8]}",
    }

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            STK_URL,
            json=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"STK push failed: {resp.text}")

    body = resp.json()
    if body.get("ResponseCode") != "0":
        raise HTTPException(
            status_code=400,
            detail=body.get("ResponseDescription", "M-Pesa rejected the request"),
        )

    # 6. Save transaction record
    txn = MpesaTransaction(
        deal_id=deal.id,
        buyer_id=current_user["id"],
        phone=phone,
        amount=amount,
        checkout_request_id=body["CheckoutRequestID"],
        merchant_request_id=body["MerchantRequestID"],
        status=MpesaStatus.pending,
    )
    db.add(txn)
    await db.commit()

    return {
        "checkout_request_id":  body["CheckoutRequestID"],
        "merchant_request_id":  body["MerchantRequestID"],
        "response_description": body.get("ResponseDescription", ""),
        "customer_message":     body.get("CustomerMessage", "Check your phone to complete payment"),
        "amount":               amount,
    }


@router.post("/query")
async def query_payment_status(
    data: StkQueryRequest,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Poll Safaricom for STK push result."""
    token = await _get_access_token()
    timestamp, password = _generate_password()

    payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          password,
        "Timestamp":         timestamp,
        "CheckoutRequestID": data.checkout_request_id,
    }

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(
            QUERY_URL,
            json=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )

    body = resp.json()

    # Mirror result to DB
    result = await db.execute(
        select(MpesaTransaction).where(
            MpesaTransaction.checkout_request_id == data.checkout_request_id
        )
    )
    txn = result.scalar_one_or_none()
    if txn:
        result_code = body.get("ResultCode")
        if str(result_code) == "0":
            txn.status = MpesaStatus.success
            deal_result = await db.execute(select(Deal).where(Deal.id == txn.deal_id))
            deal = deal_result.scalar_one_or_none()
            if deal:
                deal.status = DealStatus.paid
        elif result_code is not None and str(result_code) != "":
            txn.status = MpesaStatus.failed
        await db.commit()

    return body


@router.post("/callback")
async def mpesa_callback(request: Request, db: AsyncSession = Depends(get_db)):
    """
    Legacy path, kept only for deployments that registered this exact URL
    with Safaricom before MPESA_CALLBACK_SECRET existed. Update your Daraja
    app / M-Pesa dashboard to call /mpesa/callback/<secret> instead, then
    this route stops accepting anything at all - see the check below.

    SECURITY: this route used to log a warning and process the callback
    anyway once a secret was configured, which meant the warning did
    nothing - anyone could still POST a forged {"ResultCode": 0, ...}
    body with a guessed/observed CheckoutRequestID and have a deal marked
    paid, or a seller's rating bumped, with no real M-Pesa payment having
    happened. Fixed: once CALLBACK_SECRET is set, this route rejects
    outright rather than merely logging. It only still processes
    callbacks when NO secret is configured at all (i.e. local/sandbox
    setups that haven't set MPESA_CALLBACK_SECRET yet) - and
    validate_startup() now refuses to start in production without one
    set, so this permissive path cannot exist in a real deployment.
    """
    if CALLBACK_SECRET:
        logger.warning(
            "Rejected M-Pesa callback on the UNPROTECTED /mpesa/callback "
            "route - MPESA_CALLBACK_SECRET is configured, so only "
            "/mpesa/callback/<secret> is accepted. Update Safaricom's "
            "registered callback URL."
        )
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_mpesa_callback(request, db)


@router.post("/callback/{secret}")
async def mpesa_callback_secured(secret: str, request: Request, db: AsyncSession = Depends(get_db)):
    """Secret-protected Safaricom webhook - this is the one MPESA_CALLBACK_URL
    should point to once MPESA_CALLBACK_SECRET is set."""
    if not CALLBACK_SECRET or secret != CALLBACK_SECRET:
        # Deliberately vague/404-shaped rather than 403, so a guesser can't
        # distinguish "wrong secret" from "route doesn't exist".
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_mpesa_callback(request, db)


async def _process_mpesa_callback(request: Request, db: AsyncSession) -> dict:
    """Shared Safaricom STK callback handling for both routes above."""
    try:
        body = await request.json()
        logger.info("M-Pesa callback received: %s", body)

        stk         = body.get("Body", {}).get("stkCallback", {})
        checkout_id = stk.get("CheckoutRequestID")
        result_code = stk.get("ResultCode")
        result_desc = stk.get("ResultDesc", "")

        result = await db.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.checkout_request_id == checkout_id
            )
        )
        txn = result.scalar_one_or_none()

        if txn:
            # ── Idempotency guard (issue #6) ──────────────────────────────────
            # M-Pesa may deliver the same callback multiple times.
            # If we've already processed this transaction, ignore the duplicate.
            if getattr(txn, "callback_processed", False):
                logger.info("M-Pesa callback duplicate ignored cid=%s", checkout_id)
                return {"ResultCode": 0, "ResultDesc": "Accepted"}

            if result_code == 0:
                txn.status = MpesaStatus.success
                # Extract receipt from CallbackMetadata
                items = stk.get("CallbackMetadata", {}).get("Item", [])
                for item in items:
                    if item.get("Name") == "MpesaReceiptNumber":
                        txn.mpesa_receipt = str(item.get("Value", ""))
                    if item.get("Name") == "Amount":
                        txn.amount = float(item.get("Value", txn.amount))

                # Mark deal as paid
                deal_result = await db.execute(select(Deal).where(Deal.id == txn.deal_id))
                deal = deal_result.scalar_one_or_none()
                if deal:
                    deal.status = DealStatus.paid
                    # Bump seller rating on confirmed payment
                    seller_result = await db.execute(select(User).where(User.id == deal.seller_id))
                    seller = seller_result.scalar_one_or_none()
                    if seller:
                        seller.completed_deals += 1
                        seller.rating = round(min(5.0, seller.rating + 0.05), 2)

                # Mark as processed to prevent duplicate callbacks
                txn.callback_processed = True
                await db.commit()

                # ── Fire events AFTER commit so DB is consistent ───────────────
                await publish(MpesaCallbackReceived(
                    checkout_request_id=checkout_id or "",
                    result_code=result_code,
                    mpesa_receipt=txn.mpesa_receipt or "",
                    amount=txn.amount,
                ))
                if deal:
                    await publish(EscrowFunded(
                        deal_id=deal.id,
                        buyer_id=deal.buyer_id,
                        seller_id=deal.seller_id,
                        amount=txn.amount,
                        mpesa_receipt=txn.mpesa_receipt or "",
                    ))
            else:
                txn.status             = MpesaStatus.failed
                txn.callback_processed = True
                logger.warning("M-Pesa payment failed: %s - %s", result_code, result_desc)
                await db.commit()

    except Exception as exc:
        logger.error("Callback processing error: %s", exc)

    # Safaricom requires exactly this response
    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.get("/status/{deal_id}")
async def get_deal_payment_status(
    deal_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the latest M-Pesa transaction status for a deal."""
    result = await db.execute(
        select(MpesaTransaction)
        .where(MpesaTransaction.deal_id == deal_id)
        .order_by(MpesaTransaction.created_at.desc())
    )
    txn = result.scalar_one_or_none()
    if not txn:
        return {"status": "no_transaction", "deal_id": deal_id}

    return {
        "deal_id":             deal_id,
        "status":              txn.status.value,
        "amount":              txn.amount,
        "mpesa_receipt":       txn.mpesa_receipt,
        "checkout_request_id": txn.checkout_request_id,
        "created_at":          txn.created_at.isoformat(),
    }
