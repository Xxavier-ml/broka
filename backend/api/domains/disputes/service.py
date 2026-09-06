"""
BROKA v5.0 - Dispute Engine Service
=====================================
Central orchestrator for the dispute case workflow.

Responsibilities:
  1. Open/transition DisputeCase state (always writes a DisputeEvent)
  2. Attach evidence and trigger AI analysis
  3. Run the rule engine → recommendation → decision
  4. Manage DisputeTimer objects (create, cancel)
  5. Execute fund actions (refund 97% / release 97%) at terminal states
  6. Record every action in the immutable DisputeEvent log

What this service does NOT do:
  - Parse AI text output to decide fund actions (structured JSON only)
  - Set deal.timer_type directly (uses DisputeTimer table instead)
  - Allow any terminal state to be re-opened
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
import secrets
import string
from datetime import datetime, timedelta
from typing import Optional

import httpx
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import (
    Deal, DealStatus, User, NegotiationMessage,
    MpesaTransaction, MpesaStatus,
)
from api.models.dispute import (
    DisputeCase, DisputeEvent, DisputeEvidence, DisputeTimer,
    CaseState, CaseBranch, EventType, EvidenceType, TimerKind,
    Dispute, DisputeStatus, OptimisticLockError,
    DisputeType, DISPUTE_TYPE_META,
)
from api.core.audit import record_audit
from api.core.ledger import ledger as _ledger

logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

COMMISSION_RATE = 0.03   # 3% — buyer pays 97% net to seller
_ZAC_SECRET     = os.getenv("ZAC_SECRET", "broka-zac-secret-change-in-production")

# AI endpoints (mirrors negotiate.py)
GEMINI_API_KEY  = os.getenv("GEMINI_API_KEY", "")
GROQ_API_KEY    = os.getenv("GROQ_API_KEY", "")
GROQ_MODEL      = "llama-3.3-70b-versatile"
GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
GROQ_ENDPOINT   = "https://api.groq.com/openai/v1/chat/completions"

# OpenRouter — TESTING (2026-08): standing in for Groq, whose
# llama-3.3-70b-versatile Groq decommissioned 2026-08-16. See negotiate.py's
# module docstring for the full context and the other candidates being evaluated.
OPENROUTER_API_KEY  = os.getenv("OPENROUTER_API_KEY", "")
OPENROUTER_MODEL    = os.getenv("OPENROUTER_MODEL", "nvidia/nemotron-3-ultra-550b-a55b:free")
OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

# M-Pesa B2C
MPESA_ENV       = os.getenv("MPESA_ENV", "sandbox")
CONSUMER_KEY    = os.getenv("MPESA_CONSUMER_KEY", "")
CONSUMER_SECRET = os.getenv("MPESA_CONSUMER_SECRET", "")
SHORTCODE       = os.getenv("MPESA_SHORTCODE", "174379")
B2C_INITIATOR   = os.getenv("MPESA_B2C_INITIATOR", "")
B2C_CREDENTIAL  = os.getenv("MPESA_B2C_CREDENTIAL", "")
B2C_TIMEOUT_URL = os.getenv("MPESA_B2C_TIMEOUT_URL", "https://broka-dbjd.onrender.com/mpesa/b2c/timeout")
B2C_RESULT_URL  = os.getenv("MPESA_B2C_RESULT_URL",  "https://broka-dbjd.onrender.com/mpesa/b2c/result")
BASE_URL        = "https://api.safaricom.co.ke" if MPESA_ENV == "production" else "https://sandbox.safaricom.co.ke"
OAUTH_URL       = f"{BASE_URL}/oauth/v1/generate?grant_type=client_credentials"
B2C_URL         = f"{BASE_URL}/mpesa/b2c/v3/paymentrequest"

import base64


# ── ZAC helpers ───────────────────────────────────────────────────────────────

def _generate_zac(case_id: str, resolution: str) -> str:
    raw = f"{case_id}:{resolution}:{secrets.token_hex(8)}"
    sig = hmac.new(_ZAC_SECRET.encode(), raw.encode(), __import__("hashlib").sha256).hexdigest()[:6].upper()
    return f"ZAC-{resolution.upper()}-{sig}"


# ── AI helpers ────────────────────────────────────────────────────────────────

async def _call_gemini(system: str, messages: list, image_base64: str = "") -> str:
    if not GEMINI_API_KEY:
        raise ValueError("GEMINI_API_KEY not set")
    contents = []
    for m in messages:
        role = "model" if m["role"] == "assistant" else "user"
        parts = [{"text": m["content"]}]
        if image_base64 and m["role"] == "user":
            parts.append({"inline_data": {"mime_type": "image/jpeg", "data": image_base64}})
        contents.append({"role": role, "parts": parts})
    if not contents or contents[0]["role"] != "user":
        contents.insert(0, {"role": "user", "parts": [{"text": "Begin."}]})
    async with httpx.AsyncClient(timeout=35) as client:
        resp = await client.post(
            f"{GEMINI_ENDPOINT}?key={GEMINI_API_KEY}",
            headers={"Content-Type": "application/json"},
            json={
                "system_instruction": {"parts": [{"text": system}]},
                "contents": contents,
                "generationConfig": {"maxOutputTokens": 600, "temperature": 0.3},
            },
        )
    if resp.status_code != 200:
        raise ValueError(f"Gemini error {resp.status_code}: {resp.text[:200]}")
    return resp.json()["candidates"][0]["content"]["parts"][0]["text"].strip()


async def _call_groq(system: str, messages: list) -> str:
    if not GROQ_API_KEY:
        raise ValueError("GROQ_API_KEY not set")
    if not messages or messages[0]["role"] != "user":
        messages = [{"role": "user", "content": "Begin."}] + messages
    merged: list = []
    for m in messages:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n" + m["content"]
        else:
            merged.append({"role": m["role"], "content": m["content"]})
    async with httpx.AsyncClient(timeout=35) as client:
        resp = await client.post(
            GROQ_ENDPOINT,
            headers={"Authorization": f"Bearer {GROQ_API_KEY}", "Content-Type": "application/json"},
            json={
                "model": GROQ_MODEL, "max_tokens": 600, "temperature": 0.3,
                "messages": [{"role": "system", "content": system}] + merged,
            },
        )
    if resp.status_code != 200:
        raise ValueError(f"Groq error {resp.status_code}: {resp.text[:200]}")
    return resp.json()["choices"][0]["message"]["content"].strip()


async def _call_openrouter(system: str, messages: list) -> str:
    """Mirrors _call_groq - OpenRouter is OpenAI-compatible. See negotiate.py."""
    if not OPENROUTER_API_KEY:
        raise ValueError("OPENROUTER_API_KEY not set")
    if not messages or messages[0]["role"] != "user":
        messages = [{"role": "user", "content": "Begin."}] + messages
    merged: list = []
    for m in messages:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n" + m["content"]
        else:
            merged.append({"role": m["role"], "content": m["content"]})
    async with httpx.AsyncClient(timeout=35) as client:
        resp = await client.post(
            OPENROUTER_ENDPOINT,
            headers={
                "Authorization": f"Bearer {OPENROUTER_API_KEY}",
                "Content-Type":  "application/json",
                "HTTP-Referer":  "https://broka-dbjd.onrender.com",
                "X-Title":       "BROKA",
            },
            json={
                "model": OPENROUTER_MODEL, "max_tokens": 600, "temperature": 0.3,
                "messages": [{"role": "system", "content": system}] + merged,
            },
        )
    if resp.status_code != 200:
        raise ValueError(f"OpenRouter error {resp.status_code}: {resp.text[:200]}")
    return resp.json()["choices"][0]["message"]["content"].strip()


async def _call_ai(system: str, messages: list, image_base64: str = "") -> str:
    if GEMINI_API_KEY:
        try:
            return await _call_gemini(system, messages, image_base64)
        except Exception as e:
            logger.warning("[dispute_engine] Gemini failed: %s — trying OpenRouter", e)
    if OPENROUTER_API_KEY:
        try:
            return await _call_openrouter(system, messages)
        except Exception as e:
            logger.warning("[dispute_engine] OpenRouter failed: %s — trying Groq", e)
    if GROQ_API_KEY:
        return await _call_groq(system, messages)
    raise HTTPException(status_code=503, detail="AI not configured")


# ── M-Pesa B2C ────────────────────────────────────────────────────────────────

async def _mpesa_b2c(phone: str, amount: float, ref_id: str) -> dict:
    if not B2C_INITIATOR or not B2C_CREDENTIAL:
        logger.warning("[dispute_engine] B2C credentials not set — queued for manual processing")
        return {"success": False, "detail": "queued"}
    p = phone.strip().replace(" ", "").replace("-", "")
    if p.startswith("0"):
        p = "254" + p[1:]
    elif p.startswith("+"):
        p = p[1:]
    whole_amount = max(1, int(round(amount)))
    creds = base64.b64encode(f"{CONSUMER_KEY}:{CONSUMER_SECRET}".encode()).decode()
    async with httpx.AsyncClient(timeout=15) as client:
        tok = await client.get(OAUTH_URL, headers={"Authorization": f"Basic {creds}"})
    if tok.status_code != 200:
        return {"success": False, "detail": "oauth_failed"}
    token = tok.json()["access_token"]
    payload = {
        "InitiatorName": B2C_INITIATOR, "SecurityCredential": B2C_CREDENTIAL,
        "CommandID": "BusinessPayment", "Amount": whole_amount,
        "PartyA": SHORTCODE, "PartyB": p,
        "Remarks": f"BROKA refund {ref_id[:8].upper()}",
        "QueueTimeOutURL": B2C_TIMEOUT_URL, "ResultURL": B2C_RESULT_URL,
        "Occasion": f"BROKA-REF-{ref_id[:8].upper()}",
    }
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(B2C_URL, json=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    body = resp.json()
    if resp.status_code == 200 and body.get("ResponseCode") == "0":
        return {"success": True, "detail": body.get("ConversationID", "")}
    return {"success": False, "detail": body.get("ResponseDescription", "b2c_failed")}


# ── Rule Engine ───────────────────────────────────────────────────────────────

class RuleEngine:
    """
    Deterministic rule engine.
    AI provides a recommendation + confidence.
    Rules decide the final action.
    No fund movement without passing through here.
    """

    # Minimum AI confidence required for auto-execution without escalation
    MIN_AUTO_CONFIDENCE = 0.80

    @staticmethod
    def decide(
        branch: CaseBranch,
        ai_recommendation: str,        # "refund" | "release" | "inconclusive"
        ai_confidence: float,          # 0.0–1.0
        evidence_count: int,
        seller_responded: bool,
        buyer_trust_score: float,
        seller_trust_score: float,
    ) -> tuple[str, str]:
        """
        Returns (decision, reason).
        decision: "refund" | "release" | "escalate"
        """
        # Inconclusive AI → escalate for human review
        if ai_recommendation == "inconclusive":
            return "escalate", "AI could not determine outcome — escalated for human review"

        # Low confidence → escalate
        if ai_confidence < RuleEngine.MIN_AUTO_CONFIDENCE:
            return "escalate", (
                f"AI confidence {ai_confidence:.0%} is below {RuleEngine.MIN_AUTO_CONFIDENCE:.0%} "
                f"threshold — escalated for human review"
            )

        # Branch-specific overrides
        if branch == CaseBranch.B:
            # Goods never arrived: default refund unless seller has strong trust + responded
            if not seller_responded:
                return "refund", "Seller did not respond to non-delivery report"
            if seller_trust_score < 70:
                return "refund", "Seller trust score below threshold for release on non-delivery"

        if branch in (CaseBranch.A2, CaseBranch.A3):
            if not seller_responded:
                return "refund", "Seller did not explain the issue — defaulting to buyer protection"

        # No evidence provided in a damage/wrong-item case → escalate
        if branch in (CaseBranch.A2, CaseBranch.A3) and evidence_count == 0:
            return "escalate", "No evidence provided for item dispute — escalated for human review"

        # Trust score guards
        if ai_recommendation == "refund" and buyer_trust_score < 40:
            return "escalate", "Low buyer trust score on refund request — human review required"
        if ai_recommendation == "release" and seller_trust_score < 40:
            return "escalate", "Low seller trust score on release request — human review required"

        # AI recommendation passes all guards
        reason = (
            f"AI recommended {ai_recommendation} with {ai_confidence:.0%} confidence. "
            f"All rule checks passed (buyer_trust={buyer_trust_score:.0f}, "
            f"seller_trust={seller_trust_score:.0f}, evidence={evidence_count})"
        )
        return ai_recommendation, reason


# ── Dispute Engine Service ─────────────────────────────────────────────────────

class DisputeEngineService:
    """
    Main service. All dispute operations go through here.
    Never instantiate outside of a request/task context.
    """

    def __init__(self, db: AsyncSession):
        self.db = db

    # ─── Case Management ──────────────────────────────────────────────────────

    async def open_case(
        self,
        deal_id: str,
        opener_id: str,
        branch: CaseBranch,
        description: str,
        actor_role: str,
        ip_address: Optional[str] = None,
        dispute_type: Optional[DisputeType] = None,
    ) -> DisputeCase:
        """
        Open a new dispute case. Freezes deal funds.

        dispute_type (new, preferred): data-driven type key from DisputeType enum.
            Sets both case.dispute_type and derives case.branch for backward compat.
        branch (legacy): CaseBranch enum value. Used when dispute_type is not supplied.
            New callers should prefer dispute_type.
        """
        deal_r = await self.db.execute(select(Deal).where(Deal.id == deal_id))
        deal = deal_r.scalar_one_or_none()
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != opener_id and deal.seller_id != opener_id:
            raise HTTPException(status_code=403, detail="Not your deal")
        if deal.status in (DealStatus.released, DealStatus.refunded):
            raise HTTPException(status_code=400, detail="Deal already settled — cannot dispute")

        # The caller-supplied actor_role is not trusted for the audit trail -
        # upstream (router), it defaults to "buyer" whenever the JWT payload
        # has no role claim (it never does), so every case opened by a
        # SELLER was previously mis-logged as if a buyer opened it. Derive it
        # from the deal itself, which we've already validated opener_id
        # against above.
        actor_role = "buyer" if opener_id == deal.buyer_id else "seller"

        # Only one open case per deal
        existing_r = await self.db.execute(
            select(DisputeCase).where(
                DisputeCase.deal_id == deal_id,
                DisputeCase.state.in_([s for s in CaseState if s.is_active]),
            )
        )
        if existing_r.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="Active dispute case already exists for this deal")

        # Resolve dispute_type → branch for backward compat
        if dispute_type is not None:
            resolved_branch = dispute_type.to_branch()
            resolved_type   = dispute_type.value
        else:
            resolved_branch = branch
            resolved_type   = None

        case = DisputeCase(
            deal_id=deal_id, opener_id=opener_id,
            branch=resolved_branch, dispute_type=resolved_type,
            state=CaseState.open,
        )
        self.db.add(case)
        deal.status = DealStatus.disputed
        await self.db.flush()  # get case.id before writing events

        type_label = (DISPUTE_TYPE_META.get(dispute_type, {}).get("label")
                      if dispute_type else None)
        await self._record_event(
            case=case, event_type=EventType.case_opened,
            actor_id=opener_id, actor_role=actor_role,
            from_state=None, to_state=CaseState.open,
            description=(
                f"Dispute case opened ({resolved_type or resolved_branch.value}): "
                f"{description[:200]}"
            ),
            payload={
                "branch": resolved_branch.value,
                "dispute_type": resolved_type,
                "type_label": type_label,
                "description": description[:500],
            },
        )

        await record_audit(
            self.db, opener_id, "dispute_case_opened", "dispute_case", case.id,
            detail=f"deal_id={deal_id} branch={branch.value}", ip_address=ip_address,
        )
        await self.db.commit()
        await self.db.refresh(case)
        return case

    async def transition(
        self,
        case: DisputeCase,
        new_state: CaseState,
        actor_id: str,
        actor_role: str,
        event_type: EventType,
        description: str,
        payload: Optional[dict] = None,
        expected_version: Optional[int] = None,
    ) -> None:
        """
        Transition case to a new state and record an immutable event.

        Optimistic locking: if expected_version is provided (it always should be
        for state transitions that move money), the current case.version must
        match. If it doesn't, a concurrent write won already — raise
        OptimisticLockError so the caller can retry or return HTTP 409.
        """
        if case.state.is_terminal:
            raise HTTPException(status_code=400, detail="Case is already closed")

        # Optimistic locking check — prevents concurrent double-spend
        if expected_version is not None and case.version != expected_version:
            raise OptimisticLockError(
                f"Case {case.id} was modified concurrently "
                f"(expected version {expected_version}, got {case.version}). "
                "Please re-fetch and retry."
            )

        old_state = case.state
        case.prev_state = old_state
        case.state = new_state
        case.version = (case.version or 0) + 1
        case.updated_at = datetime.utcnow()
        if new_state.is_terminal:
            case.closed_at = datetime.utcnow()
        await self._record_event(
            case=case, event_type=event_type,
            actor_id=actor_id, actor_role=actor_role,
            from_state=old_state, to_state=new_state,
            description=description, payload=payload or {},
        )

    async def _record_event(
        self,
        case: DisputeCase,
        event_type: EventType,
        actor_id: str,
        actor_role: str,
        description: str,
        from_state: Optional[CaseState] = None,
        to_state: Optional[CaseState] = None,
        payload: Optional[dict] = None,
    ) -> DisputeEvent:
        event = DisputeEvent(
            case_id=case.id,
            deal_id=case.deal_id,
            event_type=event_type,
            actor_id=actor_id,
            actor_role=actor_role,
            from_state=from_state,
            to_state=to_state,
            description=description,
            payload=payload or {},
        )
        self.db.add(event)
        return event

    # ─── Evidence ─────────────────────────────────────────────────────────────

    async def attach_evidence(
        self,
        case: DisputeCase,
        uploader_id: str,
        uploader_role: str,
        evidence_type: EvidenceType,
        storage_url: str,
        description: str,
        image_base64: str = "",
        file_size_kb: int = 0,
    ) -> DisputeEvidence:
        """Attach a piece of evidence. If image_base64 provided, runs AI analysis."""
        file_hash = None
        if image_base64:
            file_hash = hashlib.sha256(image_base64.encode()).hexdigest()[:32]

        evidence = DisputeEvidence(
            case_id=case.id, deal_id=case.deal_id,
            uploader_id=uploader_id, uploader_role=uploader_role,
            evidence_type=evidence_type,
            storage_url=storage_url,
            file_hash=file_hash,
            file_size_kb=file_size_kb,
            description=description,
        )
        self.db.add(evidence)

        await self._record_event(
            case=case, event_type=EventType.evidence_uploaded,
            actor_id=uploader_id, actor_role=uploader_role,
            description=f"{uploader_role} uploaded {evidence_type.value}: {description[:120]}",
            payload={"evidence_type": evidence_type.value, "file_hash": file_hash},
        )

        # Run AI analysis if image provided
        if image_base64 and len(image_base64) > 100:
            await self._analyse_evidence_image(case, evidence, image_base64)

        await self.db.commit()
        await self.db.refresh(evidence)
        return evidence

    async def _analyse_evidence_image(
        self,
        case: DisputeCase,
        evidence: DisputeEvidence,
        image_base64: str,
    ) -> None:
        """Run Gemini vision analysis on a damage/fraud image. Stores structured result."""
        system = (
            "You are BROKA's impartial evidence analyst for marketplace disputes in Kenya. "
            "A buyer has submitted a photo as evidence in a dispute. "
            "Analyse the image carefully and respond in JSON only with these fields:\n"
            "{\n"
            "  \"damage_visible\": true/false,\n"
            "  \"confidence\": 0.0-1.0,\n"
            "  \"description\": \"1-3 sentence neutral factual description of what you see\",\n"
            "  \"flags_fraud\": true/false\n"
            "}\n"
            "Be factual and neutral. Do not take sides."
        )
        try:
            raw = await _call_gemini(
                system,
                [{"role": "user", "content": "Analyse this evidence image."}],
                image_base64=image_base64,
            )
            import json
            # Strip markdown fences if present
            clean = raw.replace("```json", "").replace("```", "").strip()
            parsed = json.loads(clean)
            evidence.ai_analysed    = True
            evidence.ai_analysis    = parsed.get("description", raw[:500])
            evidence.ai_confidence  = float(parsed.get("confidence", 0.5))
            evidence.ai_flags_damage = bool(parsed.get("damage_visible", False))

            await self._record_event(
                case=case, event_type=EventType.evidence_ai_analysed,
                actor_id="zeno", actor_role="system",
                description=(
                    f"AI analysed {evidence.evidence_type.value}: "
                    f"damage_visible={evidence.ai_flags_damage}, "
                    f"confidence={evidence.ai_confidence:.0%}"
                ),
                payload={
                    "damage_visible": evidence.ai_flags_damage,
                    "confidence": evidence.ai_confidence,
                    "description": evidence.ai_analysis,
                },
            )
        except Exception as exc:
            logger.error("[dispute_engine] image analysis failed: %s", exc)
            evidence.ai_analysed = False
            evidence.ai_analysis = "Analysis unavailable"

    # ─── Timers ───────────────────────────────────────────────────────────────

    async def create_timer(
        self,
        case: DisputeCase,
        timer_kind: TimerKind,
        fires_at: datetime,
        checkin_index: int = 0,
        total_checkins: int = 1,
        send_sms_on_index: Optional[int] = None,
        actor_id: str = "system",
    ) -> DisputeTimer:
        timer = DisputeTimer(
            case_id=case.id, deal_id=case.deal_id,
            timer_kind=timer_kind,
            fires_at=fires_at,
            checkin_index=checkin_index,
            total_checkins=total_checkins,
            send_sms_on_index=send_sms_on_index,
        )
        self.db.add(timer)
        await self._record_event(
            case=case, event_type=EventType.timer_started,
            actor_id=actor_id, actor_role="system",
            description=f"Timer started: {timer_kind.value} fires at {fires_at.isoformat()}",
            payload={
                "timer_kind": timer_kind.value,
                "fires_at": fires_at.isoformat(),
                "checkin_index": checkin_index,
                "total_checkins": total_checkins,
            },
        )
        return timer

    async def cancel_timers(
        self,
        case: DisputeCase,
        timer_kind: Optional[TimerKind] = None,
        reason: str = "party_responded",
        actor_id: str = "system",
    ) -> int:
        """Cancel all active timers for a case (or a specific kind). Returns count cancelled."""
        q = select(DisputeTimer).where(
            DisputeTimer.case_id == case.id,
            DisputeTimer.fired_at.is_(None),
            DisputeTimer.cancelled_at.is_(None),
        )
        if timer_kind:
            q = q.where(DisputeTimer.timer_kind == timer_kind)
        result = await self.db.execute(q)
        timers = result.scalars().all()
        now = datetime.utcnow()
        for t in timers:
            t.cancelled_at = now
            t.cancelled_reason = reason
        if timers:
            await self._record_event(
                case=case, event_type=EventType.timer_cancelled,
                actor_id=actor_id, actor_role="system",
                description=f"Cancelled {len(timers)} timer(s): {reason}",
                payload={"count": len(timers), "reason": reason,
                         "kind": timer_kind.value if timer_kind else "all"},
            )
        return len(timers)

    # ─── Rule Engine Integration ───────────────────────────────────────────────

    async def run_ai_and_decide(
        self,
        case: DisputeCase,
        deal: Deal,
        buyer: User,
        seller: User,
        issue_description: str,
    ) -> tuple[str, str]:
        """
        Run AI analysis + rule engine.
        Returns (decision, reason) where decision is "refund" | "release" | "escalate".
        Records AI recommendation and rule decision as events.
        Does NOT execute funds — caller must call execute_fund_action().
        """
        # Count evidence
        ev_r = await self.db.execute(
            select(DisputeEvidence).where(
                DisputeEvidence.case_id == case.id,
                DisputeEvidence.ai_flags_damage == True,
            )
        )
        damage_confirmed_count = len(ev_r.scalars().all())
        ev_all_r = await self.db.execute(
            select(DisputeEvidence).where(DisputeEvidence.case_id == case.id)
        )
        all_evidence = ev_all_r.scalars().all()

        # Build context for AI
        evidence_summary = "\n".join([
            f"- {e.evidence_type.value}: {e.ai_analysis or e.description or 'no analysis'}"
            for e in all_evidence
        ]) or "No evidence submitted."

        system = (
            "You are BROKA's dispute analysis engine for a Kenyan peer-to-peer marketplace. "
            "Your task is to analyse a buyer-seller dispute and output a structured JSON recommendation. "
            "You are NOT executing any payment — a human-supervised rule engine will make the final call.\n\n"
            "Respond ONLY with valid JSON, no other text:\n"
            "{\n"
            "  \"recommendation\": \"refund\" | \"release\" | \"inconclusive\",\n"
            "  \"confidence\": 0.0-1.0,\n"
            "  \"reasoning\": \"2-4 sentence explanation referencing specific facts\"\n"
            "}"
        )
        context = (
            f"Branch: {case.branch.value if case.branch else 'unknown'}\n"
            f"Issue: {issue_description[:400]}\n"
            f"Evidence:\n{evidence_summary}\n"
            f"Seller responded: {bool(case.prev_state == CaseState.waiting_seller_explanation)}\n"
            f"AI-confirmed damage: {damage_confirmed_count} piece(s)"
        )

        ai_recommendation = "inconclusive"
        ai_confidence = 0.0
        ai_reasoning = ""
        try:
            await self.transition(
                case, CaseState.ai_review,
                actor_id="zeno", actor_role="system",
                event_type=EventType.case_state_changed,
                description="AI review started",
            )
            raw = await _call_ai(system, [{"role": "user", "content": context}])
            import json
            clean = raw.replace("```json", "").replace("```", "").strip()
            parsed = json.loads(clean)
            ai_recommendation = parsed.get("recommendation", "inconclusive")
            ai_confidence = float(parsed.get("confidence", 0.0))
            ai_reasoning = parsed.get("reasoning", "")
        except Exception as exc:
            logger.error("[dispute_engine] AI analysis failed: %s", exc)
            ai_recommendation = "inconclusive"
            ai_reasoning = f"AI analysis failed: {exc}"

        case.ai_recommendation = ai_recommendation
        case.ai_confidence = ai_confidence
        case.ai_analysis_text = ai_reasoning

        await self._record_event(
            case=case, event_type=EventType.ai_recommendation_issued,
            actor_id="zeno", actor_role="system",
            description=f"AI recommends: {ai_recommendation} (confidence={ai_confidence:.0%})",
            payload={
                "recommendation": ai_recommendation,
                "confidence": ai_confidence,
                "reasoning": ai_reasoning,
            },
        )

        # Run rule engine
        buyer_trust  = float(getattr(buyer, "trust_score", 80) or 80)
        seller_trust = float(getattr(seller, "trust_score", 80) or 80)
        decision, reason = RuleEngine.decide(
            branch=case.branch or CaseBranch.B,
            ai_recommendation=ai_recommendation,
            ai_confidence=ai_confidence,
            evidence_count=len(all_evidence),
            seller_responded=(case.prev_state != CaseState.waiting_seller_explanation),
            buyer_trust_score=buyer_trust,
            seller_trust_score=seller_trust,
        )

        case.rule_decision = decision
        case.rule_decision_reason = reason

        await self._record_event(
            case=case, event_type=EventType.rule_engine_decision,
            actor_id="system", actor_role="system",
            description=f"Rule engine decision: {decision}",
            payload={"decision": decision, "reason": reason},
        )

        # Set next state
        if decision == "refund":
            await self.transition(
                case, CaseState.ready_for_refund,
                actor_id="system", actor_role="system",
                event_type=EventType.case_state_changed,
                description="Case ready for refund execution",
            )
        elif decision == "release":
            await self.transition(
                case, CaseState.ready_for_release,
                actor_id="system", actor_role="system",
                event_type=EventType.case_state_changed,
                description="Case ready for release execution",
            )
        else:  # escalate
            await self.transition(
                case, CaseState.escalated,
                actor_id="system", actor_role="system",
                event_type=EventType.case_escalated,
                description=f"Case escalated for human review: {reason}",
                payload={"reason": reason},
            )

        await self.db.commit()
        return decision, reason

    # ─── Fund Execution ───────────────────────────────────────────────────────

    async def execute_fund_action(
        self,
        case: DisputeCase,
        actor_id: str,
        actor_role: str,
    ) -> dict:
        """
        Execute the fund action (refund 97% or release 97%).
        Only valid from ready_for_refund or ready_for_release states.
        Closes the case on success.
        """
        if case.state == CaseState.ready_for_refund:
            action = "refund"
        elif case.state == CaseState.ready_for_release:
            action = "release"
        else:
            raise HTTPException(
                status_code=400,
                detail=f"Cannot execute funds in state {case.state.value}",
            )

        deal_r = await self.db.execute(select(Deal).where(Deal.id == case.deal_id))
        deal = deal_r.scalar_one()
        buyer_r = await self.db.execute(select(User).where(User.id == deal.buyer_id))
        buyer = buyer_r.scalar_one()
        seller_r = await self.db.execute(select(User).where(User.id == deal.seller_id))
        seller = seller_r.scalar_one()

        net_amount = round(deal.agreed_price * (1 - COMMISSION_RATE), 2)
        case.fund_amount = net_amount
        b2c_result = {"success": False, "detail": "not_applicable"}

        commission = round(deal.agreed_price * COMMISSION_RATE, 2)

        if action == "refund":
            if buyer.phone:
                b2c_result = await _mpesa_b2c(buyer.phone, net_amount, case.id)
            deal.status    = DealStatus.refunded
            deal.refunded_at = datetime.utcnow()
            new_state = CaseState.closed_refunded
            # Immutable ledger entry: escrow → refund_payable
            try:
                await _ledger.record_escrow_refunded(
                    self.db, deal.id, float(net_amount), case.id
                )
            except Exception as exc:
                logger.error("[dispute_engine] ledger refund entry failed: %s", exc)
            await self._record_event(
                case=case, event_type=EventType.refund_initiated,
                actor_id=actor_id, actor_role=actor_role,
                description=f"Refund of KES {net_amount:,.0f} (97%) initiated to buyer",
                payload={"amount": net_amount, "phone": buyer.phone or "", "b2c": b2c_result},
            )
        else:
            deal.status    = DealStatus.released
            deal.released_at = datetime.utcnow()
            if seller:
                seller.completed_deals = (seller.completed_deals or 0) + 1
            new_state = CaseState.closed_released
            b2c_result = {"success": True, "detail": "release_logged"}
            # Immutable ledger entry: escrow → seller_wallet + broka_revenue
            try:
                await _ledger.record_escrow_released(
                    self.db, deal.id, float(deal.agreed_price), float(commission)
                )
            except Exception as exc:
                logger.error("[dispute_engine] ledger release entry failed: %s", exc)
            await self._record_event(
                case=case, event_type=EventType.release_initiated,
                actor_id=actor_id, actor_role=actor_role,
                description=f"Release of KES {net_amount:,.0f} (97%) to seller",
                payload={"amount": net_amount, "seller_id": deal.seller_id},
            )

        case.fund_action   = action
        case.fund_executed_at = datetime.utcnow()
        case.mpesa_conversation_id = b2c_result.get("detail", "")
        zac = _generate_zac(case.id, action)
        case.zac_code = zac

        await self.cancel_timers(case, reason="case_closed")
        # Pass expected_version so the terminal transition is protected against
        # concurrent execution (e.g. timer sweep + manual execute hitting simultaneously).
        await self.transition(
            case, new_state, actor_id=actor_id, actor_role=actor_role,
            event_type=EventType.case_closed,
            description=f"Case closed: {action}",
            payload={"action": action, "amount": net_amount, "zac": zac},
            expected_version=case.version,
        )

        await record_audit(
            self.db, actor_id, f"dispute_fund_{action}", "dispute_case", case.id,
            detail=f"KES {net_amount:.0f} deal_id={case.deal_id}",
        )
        await self.db.commit()

        return {
            "case_id":    case.id,
            "action":     action,
            "amount_kes": net_amount,
            "zac_code":   zac,
            "mpesa_ok":   b2c_result["success"],
            "state":      new_state.value,
        }

    # ─── Timeline ─────────────────────────────────────────────────────────────

    async def get_timeline(self, case_id: str) -> list[dict]:
        """Full immutable event timeline for a case."""
        result = await self.db.execute(
            select(DisputeEvent)
            .where(DisputeEvent.case_id == case_id)
            .order_by(DisputeEvent.created_at.asc())
        )
        return [
            {
                "id":          e.id,
                "event_type":  e.event_type.value,
                "actor_id":    e.actor_id,
                "actor_role":  e.actor_role,
                "from_state":  e.from_state.value if e.from_state else None,
                "to_state":    e.to_state.value if e.to_state else None,
                "description": e.description,
                "payload":     e.payload,
                "created_at":  e.created_at.isoformat(),
            }
            for e in result.scalars().all()
        ]

    async def get_case_dict(self, case: DisputeCase) -> dict:
        ev_r = await self.db.execute(
            select(DisputeEvidence).where(DisputeEvidence.case_id == case.id)
        )
        evidence_list = [
            {
                "id": e.id, "type": e.evidence_type.value,
                "uploader_role": e.uploader_role,
                "storage_url": e.storage_url,
                "ai_analysis": e.ai_analysis,
                "ai_flags_damage": e.ai_flags_damage,
                "ai_confidence": e.ai_confidence,
                "description": e.description,
                "created_at": e.created_at.isoformat(),
            }
            for e in ev_r.scalars().all()
        ]
        return {
            "id":                  case.id,
            "deal_id":             case.deal_id,
            "opener_id":           case.opener_id,
            "branch":              case.branch.value if case.branch else None,
            "dispute_type":        getattr(case, "dispute_type", None),
            "dispute_type_label":  (
                DISPUTE_TYPE_META.get(DisputeType(case.dispute_type), {}).get("label")
                if getattr(case, "dispute_type", None) else None
            ),
            "state":               case.state.value,
            "ai_recommendation":   case.ai_recommendation,
            "ai_confidence":       case.ai_confidence,
            "ai_analysis_text":    case.ai_analysis_text,
            "rule_decision":       case.rule_decision,
            "rule_decision_reason": case.rule_decision_reason,
            "fund_action":         case.fund_action,
            "fund_amount":         case.fund_amount,
            "fund_executed_at":    case.fund_executed_at.isoformat() if case.fund_executed_at else None,
            "zac_code":            case.zac_code,
            "replacement_cycle":   case.replacement_cycle,
            "created_at":          case.created_at.isoformat(),
            "updated_at":          case.updated_at.isoformat() if case.updated_at else None,
            "closed_at":           case.closed_at.isoformat() if case.closed_at else None,
            "evidence":            evidence_list,
        }
