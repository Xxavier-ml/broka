"""Escrow / Deal Router v3.0"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import EscrowService

router = APIRouter()


class FinalizeDealIn(BaseModel):
    listing_id: str
    buyer_id: str
    agreed_price: float


@router.post("/finalize", status_code=201)
async def finalize_deal(
    body: FinalizeDealIn,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.finalize_deal(
        listing_id=body.listing_id,
        buyer_id=body.buyer_id,
        agreed_price=body.agreed_price,
        seller_id=current_user["id"],
        request_ip=request.client.host if request.client else None,
    )


@router.post("/{deal_id}/confirm-delivery")
async def confirm_delivery(
    deal_id: str,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.confirm_delivery(
        deal_id=deal_id,
        buyer_id=current_user["id"],
        request_ip=request.client.host if request.client else None,
    )


@router.get("/{deal_id}")
async def get_deal(
    deal_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.get_deal(deal_id, current_user["id"])


@router.get("/")
async def get_my_deals(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.get_my_deals(current_user["id"])
