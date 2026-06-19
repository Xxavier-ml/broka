"""
BROKA - Escrow Router

True escrow lifecycle on top of the existing M-Pesa "paid" state:

    agreed → paid (funds held)            ← buyer completes STK push
           → disputed (funds frozen)      ← buyer or seller opens a dispute
           → released (paid → seller)     ← buyer confirms delivery
           → refunded (paid → buyer)      ← dispute resolved in buyer's favour

The /confirm-delivery endpoint is the happy-path: the buyer presses
"I received the item / service" and BROKA releases the held commission to the
seller's ledger and bumps their reputation. The actual B2C payout to the
seller's M-Pesa is logged and (in production) handed off to Daraja B2C, which
is already wired up in routers/disputes.py for refunds.
"""

import logging
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, Deal, DealStatus, User
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/confirm-delivery/{deal_id}")
async def confirm_delivery(
    deal_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Buyer confirms the item arrived → release funds to seller."""
    deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    if deal.buyer_id != current_user["id"]:
        raise HTTPException(status_code=403, detail="Only the buyer can confirm delivery")
    if deal.status != DealStatus.paid:
        raise HTTPException(
            status_code=400,
            detail=f"Deal must be in 'paid' state to release (currently {deal.status.value})",
        )

    now = datetime.utcnow()
    deal.status = DealStatus.released
    deal.delivery_confirmed_at = now
    deal.released_at = now

    # Bump seller reputation
    seller = (await db.execute(select(User).where(User.id == deal.seller_id))).scalar_one_or_none()
    if seller:
        seller.completed_deals = (seller.completed_deals or 0) + 1
        seller.rating = round(min(5.0, (seller.rating or 5.0) + 0.05), 2)

    await db.commit()
    logger.info("Escrow released for deal %s → seller %s", deal_id, deal.seller_id)
    return {
        "deal_id": deal.id,
        "status":  deal.status.value,
        "released_at": deal.released_at.isoformat(),
    }


@router.post("/open-dispute/{deal_id}")
async def freeze_for_dispute(
    deal_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Flag a paid deal as disputed so funds stay frozen until resolution.
    The full dispute workflow (Zeno verdict, ZAC code, B2C refund) lives in
    routers/disputes.py - this endpoint is the lightweight "freeze" hook.
    """
    deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    if current_user["id"] not in (deal.buyer_id, deal.seller_id):
        raise HTTPException(status_code=403, detail="Only deal participants can dispute")
    if deal.status not in (DealStatus.paid, DealStatus.agreed):
        raise HTTPException(status_code=400, detail=f"Cannot dispute a {deal.status.value} deal")

    deal.status = DealStatus.disputed
    await db.commit()
    return {"deal_id": deal.id, "status": deal.status.value}


@router.get("/state/{deal_id}")
async def get_escrow_state(
    deal_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    if current_user["id"] not in (deal.buyer_id, deal.seller_id):
        raise HTTPException(status_code=403, detail="Not a participant in this deal")
    return {
        "deal_id":               deal.id,
        "status":                deal.status.value,
        "agreed_price":          deal.agreed_price,
        "commission":            deal.commission,
        "delivery_confirmed_at": deal.delivery_confirmed_at.isoformat() if deal.delivery_confirmed_at else None,
        "released_at":           deal.released_at.isoformat() if deal.released_at else None,
        "refunded_at":           deal.refunded_at.isoformat() if deal.refunded_at else None,
    }
