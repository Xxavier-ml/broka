"""
Escrow Service v3.0
Hardened: atomic DB operations, audit logs, fraud checks, event publishing.
"""
from __future__ import annotations

import secrets
import string
from datetime import datetime
from typing import Optional
from fastapi import HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import (
    Deal, DealStatus, Listing, User, MpesaTransaction, MpesaStatus,
)
from api.core.events import publish, DealFinalized, EscrowFunded, EscrowReleased
from api.core.audit import record_audit
from api.core.fraud import flag_fraud, compute_trust_score
from api.core.config import settings
from .repository import DealRepository, MpesaRepository


def _commission(price: float) -> float:
    return round(price * settings.commission_rate, 2)


class EscrowService:
    def __init__(self, db: AsyncSession):
        self.db = db
        self.deals = DealRepository(db)
        self.mpesa = MpesaRepository(db)

    async def finalize_deal(
        self,
        listing_id: str,
        buyer_id: str,
        agreed_price: float,
        seller_id: str,   # authenticated
        request_ip: Optional[str] = None,
    ) -> dict:
        # Validate listing ownership
        r = await self.db.execute(select(Listing).where(Listing.id == listing_id))
        listing = r.scalar_one_or_none()
        if not listing:
            raise HTTPException(status_code=404, detail="Listing not found")
        if listing.seller_id != seller_id:
            raise HTTPException(status_code=403, detail="Only the seller can finalise a deal")

        # Prevent duplicate deals
        existing = await self.deals.get_by_listing_buyer(listing_id, buyer_id)
        if existing and existing.status not in (DealStatus.cancelled,):
            return {"deal_id": existing.id, "status": existing.status.value, "existed": True}

        commission = _commission(agreed_price)
        deal = await self.deals.create(
            listing_id=listing_id,
            seller_id=seller_id,
            buyer_id=buyer_id,
            agreed_price=agreed_price,
            commission=commission,
            status=DealStatus.agreed,
        )

        # Update listing status
        listing.status = "pending"
        await self.db.commit()
        await self.db.refresh(deal)

        await record_audit(
            self.db, seller_id, "deal_finalized", "deal", deal.id,
            f"agreed_price={agreed_price} commission={commission}",
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(DealFinalized(
            deal_id=deal.id,
            listing_id=listing_id,
            seller_id=seller_id,
            buyer_id=buyer_id,
            agreed_price=agreed_price,
            commission=commission,
        ))

        return {
            "deal_id": deal.id,
            "listing_id": listing_id,
            "seller_id": seller_id,
            "buyer_id": buyer_id,
            "agreed_price": agreed_price,
            "commission": commission,
            "amount_to_pay": agreed_price + commission,
            "status": deal.status.value,
        }

    async def confirm_delivery(
        self,
        deal_id: str,
        buyer_id: str,
        request_ip: Optional[str] = None,
    ) -> dict:
        """Buyer confirms delivery → funds released to seller."""
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != buyer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can confirm delivery")
        if deal.status != DealStatus.paid:
            raise HTTPException(status_code=400, detail=f"Cannot release — deal status is '{deal.status.value}'")

        deal.status = DealStatus.released
        deal.delivery_confirmed_at = datetime.utcnow()
        deal.released_at = datetime.utcnow()

        # Increment seller's completed_deals
        r = await self.db.execute(select(User).where(User.id == deal.seller_id))
        seller = r.scalar_one_or_none()
        if seller:
            seller.completed_deals = (seller.completed_deals or 0) + 1
            # Re-score trust after successful deal
            await compute_trust_score(seller.id, self.db)

        await record_audit(
            self.db, buyer_id, "delivery_confirmed", "deal", deal_id,
            f"seller_id={deal.seller_id} amount={deal.agreed_price}",
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(EscrowReleased(
            deal_id=deal_id,
            seller_id=deal.seller_id,
            buyer_id=buyer_id,
            amount=deal.agreed_price,
        ))

        return {"ok": True, "deal_id": deal_id, "status": "released"}

    async def get_deal(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != user_id and deal.seller_id != user_id:
            raise HTTPException(status_code=403, detail="Not your deal")
        return self._deal_dict(deal)

    async def get_my_deals(self, user_id: str) -> list[dict]:
        r = await self.db.execute(
            select(Deal).where(
                (Deal.buyer_id == user_id) | (Deal.seller_id == user_id)
            ).order_by(Deal.created_at.desc())
        )
        return [self._deal_dict(d) for d in r.scalars().all()]

    @staticmethod
    def _deal_dict(deal: Deal) -> dict:
        return {
            "id": deal.id,
            "listing_id": deal.listing_id,
            "seller_id": deal.seller_id,
            "buyer_id": deal.buyer_id,
            "agreed_price": deal.agreed_price,
            "commission": deal.commission,
            "status": deal.status.value,
            "delivery_confirmed_at": deal.delivery_confirmed_at.isoformat() if deal.delivery_confirmed_at else None,
            "released_at": deal.released_at.isoformat() if deal.released_at else None,
            "refunded_at": deal.refunded_at.isoformat() if deal.refunded_at else None,
            "created_at": deal.created_at.isoformat() if deal.created_at else None,
        }


# ── Fund-safety: race-condition guard for release/refund actions ───────────
#
# Module-level, not a method, so every code path that can move money for a
# deal can import this one function - routers/negotiate.py's several
# manual buyer/seller intents and core/workers.py's automated timeout
# sweep are the two currently known to race against each other (both can
# become eligible to refund or release the SAME deal, e.g. a deal sitting
# at awaiting_resolution with an overdue timer is a valid target for both
# the sweep's due_deals query AND negotiate.py's buyer_chooses_refund
# intent). Before this, both paths did a plain SELECT with no lock and no
# re-check, so both could read the deal as still-eligible before either
# committed, and both fire a real M-Pesa B2C payout for the same deal.
async def lock_deal_if_status(
    db: AsyncSession, deal_id: str, expected_statuses: tuple,
) -> Optional[Deal]:
    """
    Row-locks the deal (SELECT ... FOR UPDATE) and returns it ONLY if its
    status is still one of expected_statuses at the moment the lock is
    acquired - None if some other transaction already moved it past that
    status. Callers MUST treat None as "already handled elsewhere, do
    nothing" rather than proceeding.

    On Postgres this is a real row lock: a concurrent transaction trying
    to lock the same row blocks until this one commits or rolls back, then
    sees the updated status and correctly gets None. On SQLite (this app's
    local/dev default - see .env.example), SQLAlchemy silently drops the
    FOR UPDATE clause since SQLite has no row-level locking - this
    function still re-checks status either way, so it's correct everywhere,
    just not lock-protected against true concurrent access in dev/test.
    That asymmetry is acceptable: SQLite is never this app's production
    database (validate_startup() in core/config.py refuses to start in
    production with one), so the dialect that matters for real concurrent
    traffic is the one where the lock actually holds.
    """
    result = await db.execute(
        select(Deal).where(Deal.id == deal_id).with_for_update()
    )
    deal = result.scalar_one_or_none()
    if deal is None or deal.status not in expected_statuses:
        return None
    return deal
