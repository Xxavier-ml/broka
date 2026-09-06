"""
BROKA - Interest Availability Nudge Tests (v6.2)
Run: pytest backend/tests/test_interest_nudges.py -v

Covers task_check_interest_nudges (api/core/workers.py): if a buyer's
interest goes unanswered past its nudge_deadline, the seller gets an SMS;
if the seller actually replied in the thread, the sweep cancels the nudge
instead. The AI draft call and the SMS provider are both mocked — this
suite checks the deterministic sweep logic (who gets texted and why), not
Gemini/Groq/Africa's Talking themselves, which are already covered
independently (ai_broker circuit breakers, sms.py sandbox routing).
"""

import pytest
import pytest_asyncio
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_interest_nudges.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def _verified_token(client, phone: str) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


async def _register_and_login(client, phone: str, name: str, email: str, password: str) -> dict:
    token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": token, "name": name, "email": email,
        "password": password, "lat": -1.28, "lng": 36.81,
    })
    resp = await client.post("/auth/login", json={"phone": phone, "password": password})
    return resp.json()


@pytest_asyncio.fixture(scope="module")
async def seller(client):
    return await _register_and_login(
        client, "0733111000", "Nudge Seller", "nudgeseller@test.ke", "NudgeSeller123!"
    )


async def _create_listing_and_interest(client, seller_token, buyer_token, name):
    create_resp = await client.post("/listings/", json={
        "name": name, "category": "electronics", "price": 20000,
        "lat": -1.286, "lng": 36.817,
    }, headers={"Authorization": f"Bearer {seller_token}"})
    assert create_resp.status_code == 201
    listing_id = create_resp.json()["id"]

    interest_resp = await client.post(f"/listings/{listing_id}/interest", json={
        "offer_price": 18000,
    }, headers={"Authorization": f"Bearer {buyer_token}"})
    assert interest_resp.status_code == 200
    return listing_id


class TestInterestNudgeSweep:

    @pytest.mark.asyncio
    async def test_express_interest_sets_nudge_deadline(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111001", "Nudge Buyer A", "nudgebuyera@test.ke", "NudgeBuyerA123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Deadline Check Phone"
        )

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()

        assert interest.nudge_deadline is not None
        assert interest.nudge_sent_at is None
        assert interest.nudge_cancelled_at is None
        # Should be ~5 minutes out, not e.g. 5 hours or unset-and-defaulted.
        delta = interest.nudge_deadline - interest.created_at
        assert timedelta(minutes=4) < delta < timedelta(minutes=6)

    @pytest.mark.asyncio
    async def test_sweep_sends_sms_when_seller_silent(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111002", "Nudge Buyer B", "nudgebuyerb@test.ke", "NudgeBuyerB123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Silent Seller Phone"
        )

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()
            # Simulate 5 minutes having already passed, instead of sleeping.
            interest.nudge_deadline = datetime.utcnow() - timedelta(seconds=1)
            await session.commit()

        mock_sms = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=mock_sms)), \
             patch(
                "api.domains.ai_broker.service.AIBrokerService.draft_availability_nudge_sms",
                new=AsyncMock(return_value="Hi Seller, it's Zeno — following up on that interest."),
             ):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})

        mock_sms.assert_called_once()
        called_phone = mock_sms.call_args.args[0]
        assert called_phone == "+254733111000"  # seller's registered phone, normalized

        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            refreshed = r.scalar_one()
        assert refreshed.nudge_sent_at is not None
        assert refreshed.nudge_cancelled_at is None

    @pytest.mark.asyncio
    async def test_sweep_cancels_when_seller_already_replied(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111003", "Nudge Buyer C", "nudgebuyerc@test.ke", "NudgeBuyerC123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Responsive Seller Phone"
        )

        from api.database import AsyncSessionLocal, Interest, NegotiationMessage
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()
            interest.nudge_deadline = datetime.utcnow() - timedelta(seconds=1)
            # Seller actually replied in the thread, after the interest was created.
            session.add(NegotiationMessage(
                listing_id=listing_id,
                sender_id=seller["user_id"],
                role="seller",
                recipient_role="buyer",
                content="Yes it's still available!",
                buyer_id=buyer["user_id"],
                via_ai=False,
                msg_type="text",
            ))
            await session.commit()

        mock_sms = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=mock_sms)):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})

        mock_sms.assert_not_called()

        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            refreshed = r.scalar_one()
        assert refreshed.nudge_cancelled_at is not None
        assert refreshed.nudge_sent_at is None
