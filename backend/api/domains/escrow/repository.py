"""Escrow / Deal Repository."""
from __future__ import annotations

from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from api.database import Deal, DealStatus, MpesaTransaction, MpesaStatus


class DealRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_id(self, deal_id: str) -> Optional[Deal]:
        r = await self.db.execute(select(Deal).where(Deal.id == deal_id))
        return r.scalar_one_or_none()

    async def get_by_listing_buyer(self, listing_id: str, buyer_id: str) -> Optional[Deal]:
        r = await self.db.execute(
            select(Deal).where(
                Deal.listing_id == listing_id,
                Deal.buyer_id == buyer_id,
            )
        )
        return r.scalar_one_or_none()

    async def create(self, **kwargs) -> Deal:
        deal = Deal(**kwargs)
        self.db.add(deal)
        await self.db.flush()  # get ID without full commit
        return deal

    async def update_status(self, deal: Deal, status: DealStatus) -> Deal:
        deal.status = status
        await self.db.flush()
        return deal


class MpesaRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_checkout_id(self, checkout_id: str) -> Optional[MpesaTransaction]:
        r = await self.db.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.checkout_request_id == checkout_id
            )
        )
        return r.scalar_one_or_none()

    async def get_latest_for_deal(self, deal_id: str) -> Optional[MpesaTransaction]:
        r = await self.db.execute(
            select(MpesaTransaction)
            .where(MpesaTransaction.deal_id == deal_id)
            .order_by(MpesaTransaction.created_at.desc())
            .limit(1)
        )
        return r.scalar_one_or_none()

    async def create(self, **kwargs) -> MpesaTransaction:
        tx = MpesaTransaction(**kwargs)
        self.db.add(tx)
        await self.db.flush()
        return tx
