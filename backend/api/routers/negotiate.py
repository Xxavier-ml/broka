"""
BROKA - AI Broker (Negotiation Engine)
Primary:  Gemini 2.0 Flash - advanced multilingual support (Swahili, Dholuo, Kikuyu, Luganda, Sheng).
Fallback: Groq (llama-3.3-70b-versatile) - high free-tier quota backup.

SUPPORTED LANGUAGES:
  English, Kiswahili, Dholuo, Kikuyu, Luganda, Sheng

PRIVACY MODEL:
  - When the buyer sends a message, TWO broker replies are generated:
      • One addressed to the BUYER  (acknowledgement)
      • One addressed to the SELLER (notification)
  - Each is stored with recipient_role = "buyer" or "seller".
  - The /history endpoint filters by the caller's JWT role.
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, or_
from pydantic import BaseModel
from typing import List, Optional
import httpx
import os
import math
import logging

from api.database import get_db, NegotiationMessage, Listing, User
from datetime import datetime as _dt
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

# ── AI Provider config ────────────────────────────────────────────────────────

GEMINI_API_KEY  = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL    = "gemini-2.0-flash"
GEMINI_ENDPOINT = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"

GROQ_API_KEY  = os.getenv("GROQ_API_KEY", "")
GROQ_MODEL    = "llama-3.3-70b-versatile"
GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"

COMMISSION_RATE = 0.03
MAX_HISTORY     = 20

# ── Language definitions ──────────────────────────────────────────────────────

SUPPORTED_LANGUAGES = {
    "english": {
        "name": "English",
        "instruction": "Respond entirely in English.",
    },
    "swahili": {
        "name": "Kiswahili",
        "instruction": "Jibu kwa Kiswahili chote. Tumia Kiswahili safi cha kawaida.",
    },
    "luo": {
        "name": "Dholuo",
        "instruction": "Dwok e Dholuo. Tiyo gi weche mag Dholuo maber.",
    },
    "kikuyu": {
        "name": "Kikuyu",
        "instruction": "Ũhote kũgeria gũcaria ũhoro wa Kikuyu. Andika na Gĩkũyũ.",
    },
    "luganda": {
        "name": "Luganda",
        "instruction": "Ddamu mu Luganda. Kozesa Luganda ennungi.",
    },
    "sheng": {
        "name": "Sheng",
        "instruction": "Respond in Sheng - the Nairobi urban mix of Swahili, English and local languages. Keep it natural and street-smart.",
    },
}

DEFAULT_LANGUAGE = "english"


def _language_instruction(lang: Optional[str]) -> str:
    key   = (lang or DEFAULT_LANGUAGE).lower()
    entry = SUPPORTED_LANGUAGES.get(key, SUPPORTED_LANGUAGES[DEFAULT_LANGUAGE])
    return entry["instruction"]


# ── Base prompts ──────────────────────────────────────────────────────────────

BROKER_BASE_PROMPT = """
You are BROKA - an AI-powered, impartial marketplace broker operating in East Africa.

YOUR MISSION:
- Facilitate fair, transparent negotiations between buyers and sellers.
- Protect BOTH parties equally. Never exploit anyone.
- Work toward a WIN-WIN deal where both parties feel satisfied.
- Be concise, friendly, and professional.
- ALWAYS address users by their first name - make the conversation personal and human.

YOUR RULES:
1. Never inflate the price beyond what the seller set.
2. Never hide information from either party.
3. Focus on trust, escrow payments, fraud protection, verified deals, and safety.
4. Suggest fair compromises when parties are far apart.
5. Propose creative solutions: payment plans, included extras, viewing arrangements.
6. When both parties agree, summarise the deal clearly and prompt contact exchange.
7. Keep messages short (2-4 sentences max per turn).
8. If asked about fees: BROKA charges a 3% transaction fee covering escrow protection and fraud prevention.
9. HONESTY RULE: Only say you are searching for buyers/sellers if matches were actually found. Never pretend to search the database.

TONE: Warm, trustworthy, efficient. Like a knowledgeable friend helping two people make a fair deal.
""".strip()

FREE_CHAT_PROMPT = BROKER_BASE_PROMPT + """

IMPORTANT - FREE CHAT MODE:
Always greet and refer to the user by their first name.
Be honest about what BROKA can and cannot do.
Do NOT claim to be searching the database unless matches were found.
"""

ZENO_PROMPT = """
You are ZENO - the intelligent AI assistant for the BROKA marketplace platform.
YOUR IDENTITY: Name: Zeno. Role: Platform intelligence, advisor, decision-making guide.
Personality: Sharp, knowledgeable, friendly, concise. Like a brilliant friend who knows East African markets.
You are DIFFERENT from the AI Broker (which mediates specific deals). You give broader advice.
WHAT YOU KNOW: How BROKA works (listings, escrow, verified media, auction vs direct, 3% fee).
Market pricing in Kenya and East Africa (vehicles, property, electronics, livestock).
How to negotiate, when to trust a deal, how to read trust scores.
RULES: Short responses (3-5 sentences unless asked for detail). Always honest.
Never claim to search the database in real time - give knowledge-based advice.
""".strip()


# ── Pydantic Schemas ──────────────────────────────────────────────────────────

class MessageIn(BaseModel):
    listing_id:   str
    sender_role:  str
    sender_id:    str
    content:      str
    buyer_name:   Optional[str] = None
    seller_name:  Optional[str] = None
    buyer_lat:    Optional[float] = None
    buyer_lng:    Optional[float] = None
    seller_lat:   Optional[float] = None
    seller_lng:   Optional[float] = None
    language:     Optional[str] = None


class ChatIn(BaseModel):
    content:         str
    history:         List[dict] = []
    user_name:       Optional[str] = None
    system_override: Optional[str] = None
    language:        Optional[str] = None


class MessageOut(BaseModel):
    role:    str
    content: str
    deal_probability: Optional[int] = None


# ── Individual AI callers ─────────────────────────────────────────────────────

async def _call_gemini(system: str, messages: List[dict]) -> str:
    """
    Call Gemini 2.0 Flash.
    Best for: multilingual African languages (Dholuo, Kikuyu, Luganda, Sheng).
    Raises ValueError on any failure so _call_ai can fall back to Groq.
    """
    if not GEMINI_API_KEY:
        raise ValueError("GEMINI_API_KEY not set")

    contents = []
    for m in messages:
        role = "model" if m["role"] == "assistant" else "user"
        contents.append({"role": role, "parts": [{"text": m["content"]}]})

    # Gemini requires first turn to be user
    if not contents or contents[0]["role"] != "user":
        contents.insert(0, {"role": "user", "parts": [{"text": "Begin."}]})

    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{GEMINI_ENDPOINT}?key={GEMINI_API_KEY}",
            headers={"Content-Type": "application/json"},
            json={
                "system_instruction": {"parts": [{"text": system}]},
                "contents": contents,
                "generationConfig": {
                    "maxOutputTokens": 400,
                    "temperature":     0.75,
                },
            },
        )

    if response.status_code == 429:
        raise ValueError(f"Gemini quota exceeded - falling back to Groq")
    if response.status_code != 200:
        raise ValueError(f"Gemini error {response.status_code}: {response.text[:200]}")

    data = response.json()
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()


async def _call_groq(system: str, messages: List[dict]) -> str:
    """
    Call Groq llama-3.3-70b-versatile.
    Fallback when Gemini quota is exhausted or unavailable.
    14,400 req/day free tier.
    Raises ValueError on any failure.
    """
    if not GROQ_API_KEY:
        raise ValueError("GROQ_API_KEY not set")

    # Groq requires strictly alternating user/assistant turns
    # Ensure first message is user
    if not messages or messages[0]["role"] != "user":
        messages = [{"role": "user", "content": "Begin."}] + messages

    # Merge consecutive same-role messages
    merged: List[dict] = []
    for m in messages:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n" + m["content"]
        else:
            merged.append({"role": m["role"], "content": m["content"]})

    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            GROQ_ENDPOINT,
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type":  "application/json",
            },
            json={
                "model":       GROQ_MODEL,
                "max_tokens":  400,
                "temperature": 0.75,
                "messages":    [{"role": "system", "content": system}] + merged,
            },
        )

    if response.status_code == 429:
        raise ValueError(f"Groq quota exceeded")
    if response.status_code != 200:
        raise ValueError(f"Groq error {response.status_code}: {response.text[:200]}")

    return response.json()["choices"][0]["message"]["content"].strip()


async def _call_ai(system: str, messages: List[dict]) -> str:
    """
    Master AI caller.
    1. Try Gemini first - better multilingual African language support.
    2. If Gemini fails (quota, timeout, error) - fall back to Groq automatically.
    3. If both fail - return HTTP 502 with a clear error.
    """
    # ── Primary: Gemini ───────────────────────────────────────────────────────
    if GEMINI_API_KEY:
        try:
            return await _call_gemini(system, messages)
        except httpx.TimeoutException:
            logger.warning("Gemini timed out - falling back to Groq")
        except ValueError as e:
            logger.warning("Gemini failed (%s) - falling back to Groq", e)
        except Exception as e:
            logger.warning("Gemini unexpected error (%s) - falling back to Groq", e)

    # ── Fallback: Groq ────────────────────────────────────────────────────────
    if GROQ_API_KEY:
        try:
            logger.info("Using Groq fallback")
            return await _call_groq(system, messages)
        except httpx.TimeoutException:
            logger.error("Groq also timed out")
            raise HTTPException(status_code=504, detail="AI timed out - please retry")
        except ValueError as e:
            logger.error("Groq also failed: %s", e)
            raise HTTPException(status_code=502, detail="AI temporarily unavailable - both providers failed")
        except Exception as e:
            logger.error("Groq unexpected error: %s", e)
            raise HTTPException(status_code=502, detail="AI temporarily unavailable")

    # ── Neither key configured ────────────────────────────────────────────────
    raise HTTPException(
        status_code=503,
        detail="AI not configured - set GEMINI_API_KEY and GROQ_API_KEY in Render environment",
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def _compute_deal_probability(history: List[NegotiationMessage], latest_content: str) -> int:
    """
    Lightweight keyword-based sentiment scoring to estimate deal probability (0-100).
    Not AI-based - keeps this cheap to run on every message.
    """
    positive_words = ["accept", "deal", "agree", "good", "fair", "ok", "fine",
                      "yes", "perfect", "great", "reasonable", "sawa", "okay",
                      "ndio", "kabisa", "poa", "safi", "approved"]
    negative_words = ["no", "reject", "expensive", "too much", "cancel", "never",
                      "impossible", "ridiculous", "hapana", "ghali", "too high",
                      "not interested", "walk away", "forget it"]
    progress_words = ["offer", "price", "how about", "what if", "consider",
                      "negotiate", "reduce", "lower", "counter", "propose"]

    pos_score = 0
    neg_score = 0
    prog_score = 0

    relevant = [m for m in history if m.role in ("buyer", "seller")][-10:]

    for msg in relevant:
        text = msg.content.lower()
        for w in positive_words:
            if w in text: pos_score += 1
        for w in negative_words:
            if w in text: neg_score += 1
        for w in progress_words:
            if w in text: prog_score += 1

    latest_lower = latest_content.lower()
    for w in positive_words:
        if w in latest_lower: pos_score += 2
    for w in negative_words:
        if w in latest_lower: neg_score += 2
    for w in progress_words:
        if w in latest_lower: prog_score += 1

    base = 50
    prob = base + (pos_score * 5) - (neg_score * 8) + (prog_score * 3)
    prob += min((len(relevant) + 1) * 2, 20)
    return max(5, min(95, int(prob)))


def _haversine_km(lat1, lng1, lat2, lng2):
    R    = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a    = (math.sin(dlat / 2) ** 2
            + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
            * math.sin(dlng / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


def _context_block(listing, seller, b_name, dist_str) -> str:
    return f"""

NEGOTIATION CONTEXT:
- Product:           {listing.name}
- Category:          {listing.category}
- Asking price:      KES {listing.price:,.0f}
- Location:          {listing.location_name or 'East Africa'}
- Listing type:      {listing.listing_type}

PARTICIPANTS:
- Seller:            {seller.name}
- Seller rating:     {seller.rating:.1f}/5.0
- Seller deals done: {seller.completed_deals}
- Buyer:             {b_name}
{dist_str}"""


def _system_for_buyer(listing, seller, b_name, dist_str, lang) -> str:
    return (BROKER_BASE_PROMPT + _context_block(listing, seller, b_name, dist_str)
            + f"""

YOUR TASK - REPLY TO THE BUYER:
You are writing a message ONLY the buyer ({b_name}) will see.
- Acknowledge their message and confirm you passed it to the seller.
- Reassure them you are working toward the best outcome.
- Address the buyer as "{b_name.split()[0]}".
- Keep it to 2 sentences max.

LANGUAGE INSTRUCTION: {_language_instruction(lang)}
""")


def _system_for_seller(listing, seller, b_name, dist_str, lang) -> str:
    s_first = seller.name.split()[0]
    return (BROKER_BASE_PROMPT + _context_block(listing, seller, b_name, dist_str)
            + f"""

YOUR TASK - NOTIFY THE SELLER:
You are writing a message ONLY the seller ({seller.name}) will see.
- Inform the seller what the buyer ({b_name}) said or wants.
- Give the seller helpful context or a suggested response.
- Address the seller as "{s_first}".
- Keep it to 2-3 sentences max.

LANGUAGE INSTRUCTION: {_language_instruction(lang)}
""")


def _system_for_buyer_from_seller(listing, seller, b_name, dist_str, lang) -> str:
    return (BROKER_BASE_PROMPT + _context_block(listing, seller, b_name, dist_str)
            + f"""

YOUR TASK - NOTIFY THE BUYER:
You are writing a message ONLY the buyer ({b_name}) will see.
- Relay what the seller ({seller.name}) said, neutrally and helpfully.
- Give the buyer advice on how to respond.
- Address the buyer as "{b_name.split()[0]}".
- Keep it to 2-3 sentences max.

LANGUAGE INSTRUCTION: {_language_instruction(lang)}
""")


def _system_for_seller_ack(listing, seller, b_name, dist_str, lang) -> str:
    s_first = seller.name.split()[0]
    return (BROKER_BASE_PROMPT + _context_block(listing, seller, b_name, dist_str)
            + f"""

YOUR TASK - ACKNOWLEDGE THE SELLER:
You are writing a message ONLY the seller ({seller.name}) will see.
- Confirm you received their message and passed it to the buyer.
- Address the seller as "{s_first}".
- Keep it to 1-2 sentences max.

LANGUAGE INSTRUCTION: {_language_instruction(lang)}
""")


def _build_messages_for_party(history, new_message, viewer_role) -> List[dict]:
    raw = []
    for msg in history[-MAX_HISTORY:]:
        if msg.role == "broker":
            if msg.recipient_role is None or msg.recipient_role == viewer_role:
                raw.append({"role": "assistant", "content": msg.content})
        else:
            label = "Seller" if msg.role == "seller" else "Buyer"
            raw.append({"role": "user", "content": f"[{label}]: {msg.content}"})

    label = "Seller" if new_message.sender_role == "seller" else "Buyer"
    raw.append({"role": "user", "content": f"[{label}]: {new_message.content}"})

    merged = []
    for m in raw:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n" + m["content"]
        else:
            merged.append({"role": m["role"], "content": m["content"]})

    if not merged or merged[0]["role"] != "user":
        merged.insert(0, {"role": "user", "content": "Begin mediation."})

    return merged


# ── Routes ────────────────────────────────────────────────────────────────────

@router.post("/chat", response_model=MessageOut)
async def free_chat(data: ChatIn):
    """Free-form AI chat - BROKA or Zeno. Supports language preference."""
    trimmed  = data.history[-MAX_HISTORY:]
    messages = trimmed + [{"role": "user", "content": data.content}]

    lang_instruction = _language_instruction(data.language)

    if (data.system_override or "").lower() in ("zeno", "xxeno"):
        system = ZENO_PROMPT
        if data.user_name:
            system += f"\n\nCURRENT USER: {data.user_name}\nAddress this user as '{data.user_name.split()[0]}'."
    else:
        system = FREE_CHAT_PROMPT
        if data.user_name:
            system += f"\n\nCURRENT USER: {data.user_name}\nAddress this user as '{data.user_name}'."

    system += f"\n\nLANGUAGE INSTRUCTION: {lang_instruction}"

    reply = await _call_ai(system, messages)
    return MessageOut(role="broker", content=reply)


@router.post("/message", response_model=MessageOut)
async def send_message(
    data: MessageIn,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Send a negotiation message.
    Role derived from JWT. Two broker replies generated - one per party.
    Gemini primary, Groq fallback.
    """
    authenticated_uid = current_user["id"]

    result = await db.execute(select(Listing).where(Listing.id == data.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    result = await db.execute(select(User).where(User.id == listing.seller_id))
    seller = result.scalar_one_or_none()
    if not seller:
        raise HTTPException(status_code=404, detail="Seller not found")

    actual_role = "seller" if authenticated_uid == listing.seller_id else "buyer"

    if data.sender_role != actual_role:
        raise HTTPException(status_code=403,
            detail=f"Role mismatch: you are the {actual_role} of this listing.")
    if data.sender_id != authenticated_uid:
        raise HTTPException(status_code=403,
            detail="sender_id does not match authenticated user.")

    buyer = None
    if actual_role == "buyer":
        result = await db.execute(select(User).where(User.id == authenticated_uid))
        buyer = result.scalar_one_or_none()

    b_name = (buyer.name if buyer else data.buyer_name) or "the buyer"
    b_lat  = (buyer.lat  if buyer else data.buyer_lat)
    b_lng  = (buyer.lng  if buyer else data.buyer_lng)

    dist_str = ""
    if b_lat and b_lng and seller.lat and seller.lng:
        km       = _haversine_km(b_lat, b_lng, seller.lat, seller.lng)
        dist_str = f"- Distance between them: {km:.1f} km\n"

    result = await db.execute(
        select(NegotiationMessage)
        .where(NegotiationMessage.listing_id == data.listing_id)
        .order_by(NegotiationMessage.created_at)
    )
    history = list(result.scalars().all())

    db.add(NegotiationMessage(
        listing_id=data.listing_id,
        sender_id=data.sender_id,
        role=data.sender_role,
        recipient_role=None,
        content=data.content,
    ))
    await db.commit()

    import asyncio

    lang = data.language

    if actual_role == "buyer":
        sys_sender  = _system_for_buyer(listing, seller, b_name, dist_str, lang)
        sys_other   = _system_for_seller(listing, seller, b_name, dist_str, lang)
        msgs_sender = _build_messages_for_party(history, data, "buyer")
        msgs_other  = _build_messages_for_party(history, data, "seller")
        sender_role = "buyer"
        other_role  = "seller"
    else:
        sys_sender  = _system_for_seller_ack(listing, seller, b_name, dist_str, lang)
        sys_other   = _system_for_buyer_from_seller(listing, seller, b_name, dist_str, lang)
        msgs_sender = _build_messages_for_party(history, data, "seller")
        msgs_other  = _build_messages_for_party(history, data, "buyer")
        sender_role = "seller"
        other_role  = "buyer"

    reply_sender, reply_other = await asyncio.gather(
        _call_ai(sys_sender, msgs_sender),
        _call_ai(sys_other,  msgs_other),
    )

    db.add(NegotiationMessage(listing_id=data.listing_id, sender_id="broker",
        role="broker", recipient_role=sender_role, content=reply_sender))
    db.add(NegotiationMessage(listing_id=data.listing_id, sender_id="broker",
        role="broker", recipient_role=other_role, content=reply_other))
    await db.commit()

    deal_probability = _compute_deal_probability(history, data.content)

    return MessageOut(role="broker", content=reply_sender, deal_probability=deal_probability)


@router.post("/direct-message")
async def direct_message(
    data: MessageIn,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Persist a direct buyer↔seller chat message (no AI reply).
    Used when the user toggles AI assist OFF in negotiation_screen.
    """
    authenticated_uid = current_user["id"]

    result = await db.execute(select(Listing).where(Listing.id == data.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    actual_role = "seller" if authenticated_uid == listing.seller_id else "buyer"
    if data.sender_role != actual_role:
        raise HTTPException(status_code=403,
            detail=f"Role mismatch: you are the {actual_role} of this listing.")
    if data.sender_id != authenticated_uid:
        raise HTTPException(status_code=403,
            detail="sender_id does not match authenticated user.")

    recipient = "seller" if actual_role == "buyer" else "buyer"
    db.add(NegotiationMessage(
        listing_id=data.listing_id,
        sender_id=data.sender_id,
        role=data.sender_role,
        recipient_role=recipient,
        content=data.content,
    ))
    await db.commit()
    return {"ok": True}




@router.get("/{listing_id}/history", response_model=List[MessageOut])
async def get_history(
    listing_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Return negotiation history for the authenticated user."""
    authenticated_uid = current_user["id"]

    result = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    actual_role = "seller" if authenticated_uid == listing.seller_id else "buyer"

    result = await db.execute(
        select(NegotiationMessage)
        .where(NegotiationMessage.listing_id == listing_id)
        .order_by(NegotiationMessage.created_at)
    )
    all_msgs = result.scalars().all()

    filtered = []
    for m in all_msgs:
        if m.role == "broker":
            if m.recipient_role is None or m.recipient_role == actual_role:
                filtered.append(MessageOut(role="broker", content=m.content))
        elif m.role == actual_role and m.sender_id == authenticated_uid:
            filtered.append(MessageOut(role=m.role, content=m.content))

    return filtered


@router.get("/inbox/{user_id}")
async def get_inbox(
    user_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Return all negotiation threads for the authenticated user."""
    if current_user["id"] != user_id:
        raise HTTPException(status_code=403, detail="Cannot access another user's inbox.")

    result = await db.execute(
        select(NegotiationMessage.listing_id)
        .where(NegotiationMessage.sender_id == user_id,
               NegotiationMessage.role == "buyer")
        .distinct()
    )
    buyer_listing_ids = [r[0] for r in result.all()]

    result2 = await db.execute(
        select(NegotiationMessage.listing_id)
        .join(Listing, NegotiationMessage.listing_id == Listing.id)
        .where(Listing.seller_id == user_id)
        .distinct()
    )
    seller_listing_ids = [r[0] for r in result2.all()]

    all_ids = list(set(buyer_listing_ids + seller_listing_ids))
    if not all_ids:
        return []

    threads = []
    for lid in all_ids:
        l_result = await db.execute(
            select(Listing, User)
            .join(User, Listing.seller_id == User.id)
            .where(Listing.id == lid)
        )
        row = l_result.one_or_none()
        if not row:
            continue
        listing, seller = row

        my_role = "seller" if seller.id == user_id else "buyer"

        latest_result = await db.execute(
            select(NegotiationMessage)
            .where(
                NegotiationMessage.listing_id == lid,
                NegotiationMessage.role == "broker",
                or_(NegotiationMessage.recipient_role == my_role,
                    NegotiationMessage.recipient_role == None),  # noqa: E711
            )
            .order_by(NegotiationMessage.created_at.desc())
            .limit(1)
        )
        last_broker = latest_result.scalar_one_or_none()

        if not last_broker:
            fallback = await db.execute(
                select(NegotiationMessage)
                .where(NegotiationMessage.listing_id == lid)
                .order_by(NegotiationMessage.created_at.desc())
                .limit(1)
            )
            last_msg = fallback.scalar_one_or_none()
        else:
            last_msg = last_broker

        if not last_msg:
            continue

        unread_result = await db.execute(
            select(func.count(NegotiationMessage.id))
            .where(NegotiationMessage.listing_id == lid,
                   NegotiationMessage.role == "broker",
                   NegotiationMessage.recipient_role == my_role)
        )
        unread = unread_result.scalar() or 0

        diff   = _dt.utcnow() - last_msg.created_at
        secs   = int(diff.total_seconds())
        if secs < 60:      time_ago = f"{secs}s ago"
        elif secs < 3600:  time_ago = f"{secs//60}m ago"
        elif secs < 86400: time_ago = f"{secs//3600}h ago"
        else:              time_ago = f"{secs//86400}d ago"

        # ── Counterpart info (buyer if I'm seller, seller if I'm buyer) ────────
        buyer_info = None
        if my_role == "seller":
            buyer_msg_result = await db.execute(
                select(NegotiationMessage.sender_id)
                .where(NegotiationMessage.listing_id == lid,
                       NegotiationMessage.role == "buyer")
                .limit(1)
            )
            buyer_id = buyer_msg_result.scalar_one_or_none()
            if buyer_id:
                buyer_result = await db.execute(select(User).where(User.id == buyer_id))
                buyer_info = buyer_result.scalar_one_or_none()

        counterpart = buyer_info if my_role == "seller" else seller
        counterpart_photo = counterpart.profile_photo if counterpart else None
        counterpart_name  = counterpart.name if counterpart else (seller.name if my_role == "buyer" else "Buyer")
        counterpart_id    = counterpart.id if counterpart else None

        # Online status for counterpart
        is_online = False
        last_seen_str = "Recently active"
        if counterpart and counterpart.last_seen:
            delta2 = _dt.utcnow() - counterpart.last_seen
            secs2 = int(delta2.total_seconds())
            is_online = secs2 < 300
            if secs2 < 60:      last_seen_str = "Active now"
            elif secs2 < 3600:  last_seen_str = f"Active {secs2//60}m ago"
            elif secs2 < 86400: last_seen_str = f"Active {secs2//3600}h ago"
            else:               last_seen_str = f"Active {secs2//86400}d ago"

        threads.append({
            "listing_id":         listing.id,
            "listing_name":       listing.name,
            "listing_category":   listing.category,
            "listing_price":      listing.price,
            "location_name":      listing.location_name,
            "listing_type":       listing.listing_type,
            "seller_id":          seller.id,
            "seller_name":        seller.name,
            "seller_photo":       seller.profile_photo,
            "buyer_id":           buyer_info.id if buyer_info else None,
            "buyer_name":         buyer_info.name if buyer_info else None,
            "buyer_photo":        buyer_info.profile_photo if buyer_info else None,
            "counterpart_id":     counterpart_id,
            "counterpart_name":   counterpart_name,
            "counterpart_photo":  counterpart_photo,
            "is_online":          is_online,
            "last_seen":          last_seen_str,
            "last_message":       last_msg.content[:80],
            "last_role":          last_msg.role,
            "unread":             unread,
            "time_ago":           time_ago,
            "my_role":            my_role,
        })

    threads.sort(key=lambda x: x["time_ago"])
    return threads
