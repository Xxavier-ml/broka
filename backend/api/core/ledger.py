from __future__ import annotations

import logging
from decimal import Decimal
from typing import Optional

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.escrow_ledger import LedgerEntry, LedgerAccount, LedgerDirection

logger = logging.getLogger(__name__)


class EscrowLedger:
    async def _entry(self, db, deal_id, account, direction, amount, description, ref_id=None):
        e = LedgerEntry(deal_id=deal_id, account=account, direction=direction,
                        amount_kes=amount, description=description, ref_id=ref_id)
        db.add(e)
        return e

    async def record_escrow_funded(self, db, deal_id, buyer_id, amount, mpesa_receipt):
        amt = Decimal(str(amount))
        await self._entry(db, deal_id, LedgerAccount.buyer_wallet, LedgerDirection.debit,
                          amt, f"Buyer payment via M-Pesa {mpesa_receipt}", mpesa_receipt)
        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.credit,
                          amt, f"Escrow funded for deal {deal_id}", mpesa_receipt)
        logger.info("[ledger] escrow funded deal=%s amount=%.2f", deal_id, amount)

    async def record_escrow_released(self, db, deal_id, amount, commission, mpesa_receipt=None):
        amt = Decimal(str(amount))
        comm = Decimal(str(commission))
        net = amt - comm
        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.debit,
                          amt, "Escrow released on delivery confirmation", mpesa_receipt)
        await self._entry(db, deal_id, LedgerAccount.seller_wallet, LedgerDirection.credit,
                          net, "Seller payout (net of commission)", mpesa_receipt)
        await self._entry(db, deal_id, LedgerAccount.broka_revenue, LedgerDirection.credit,
                          comm, "BROKA commission 3%", mpesa_receipt)
        logger.info("[ledger] escrow released deal=%s net=%.2f comm=%.2f", deal_id, float(net), float(comm))

    async def record_escrow_refunded(self, db, deal_id, amount, dispute_id):
        amt = Decimal(str(amount))
        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.debit,
                          amt, f"Escrow refunded — dispute {dispute_id}", dispute_id)
        await self._entry(db, deal_id, LedgerAccount.refund_payable, LedgerDirection.credit,
                          amt, f"Buyer refund pending — dispute {dispute_id}", dispute_id)
        logger.info("[ledger] escrow refunded deal=%s amount=%.2f dispute=%s", deal_id, amount, dispute_id)

    async def escrow_balance(self, db, deal_id):
        credits_q = select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
            LedgerEntry.deal_id == deal_id,
            LedgerEntry.account == LedgerAccount.escrow_holding,
            LedgerEntry.direction == LedgerDirection.credit)
        debits_q = select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
            LedgerEntry.deal_id == deal_id,
            LedgerEntry.account == LedgerAccount.escrow_holding,
            LedgerEntry.direction == LedgerDirection.debit)
        c = (await db.execute(credits_q)).scalar() or Decimal("0")
        d = (await db.execute(debits_q)).scalar() or Decimal("0")
        return Decimal(str(c)) - Decimal(str(d))

    async def trial_balance(self, db):
        total_credits = (await db.execute(
            select(func.sum(LedgerEntry.amount_kes)).where(
                LedgerEntry.direction == LedgerDirection.credit))).scalar() or Decimal("0")
        total_debits = (await db.execute(
            select(func.sum(LedgerEntry.amount_kes)).where(
                LedgerEntry.direction == LedgerDirection.debit))).scalar() or Decimal("0")
        return {"total_credits_kes": float(total_credits), "total_debits_kes": float(total_debits),
                "balanced": total_credits == total_debits,
                "discrepancy_kes": float(abs(total_credits - total_debits))}


ledger = EscrowLedger()
