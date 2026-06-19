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

logger = logging.getLogger(__name__)
router = APIRouter()

# ── Config ────────────────────────────────────────────────────────────────────

MPESA_ENV      = os.getenv("MPESA_ENV", "sandbox")
CONSUMER_KEY   = os.getenv("MPESA_CONSUMER_KEY", "")
CONSUMER_SECRET= os.getenv("MPESA_CONSUMER_SECRET", "")
SHORTCODE      = os.getenv("MPESA_SHORTCODE", "174379")
PASSKEY        = os.getenv("MPESA_PASSKEY", "")
CALLBACK_URL   = os.getenv("MPESA_CALLBACK_URL", "https://broka-dbjd.onrender.com/mpesa/callback")

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
    Safaricom webhook - no JWT auth (Safaricom calls this directly).
    Updates transaction and deal status.
    """
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
            else:
                txn.status = MpesaStatus.failed
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
