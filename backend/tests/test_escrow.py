"""
BROKA - Escrow & Deal Tests (v3.0)
Tests deal finalization, delivery confirmation, audit log creation.
Run: pytest backend/tests/test_escrow.py -v
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_escrow.db"
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
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def _verified_token(client, phone: str) -> str:
    """Runs otp/request -> otp/verify, returns a phone_verify_token.

    v6.1 registration is phone-first: register requires a verified-phone
    token instead of a bare phone number (see test_auth.py).
    """
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


@pytest_asyncio.fixture(scope="module")
async def tokens(client):
    # Register seller
    # NOTE: this phone must stay unique across the whole test session, not
    # just this file. See CHANGES.md — api.database builds its engine from
    # DATABASE_URL once at import time, so every test module actually shares
    # one process-wide DB despite each file monkeypatching its own path;
    # "0711223344" used to collide with test_categories.py and caused a 409
    # here (registration is phone-first, so double-booking a phone number is
    # rejected).
    seller_phone = "0722334455"
    seller_verify_token = await _verified_token(client, seller_phone)
    await client.post("/auth/register", json={
        "phone_verify_token": seller_verify_token,
        "name": "Seller Dan", "email": "dan@test.ke",
        "password": "DanPass123!",
        "lat": -1.3, "lng": 36.8,
    })
    seller = (await client.post("/auth/login", json={
        "phone": seller_phone, "password": "DanPass123!",
    })).json()

    # Register buyer
    buyer_phone = "0755667788"
    buyer_verify_token = await _verified_token(client, buyer_phone)
    await client.post("/auth/register", json={
        "phone_verify_token": buyer_verify_token,
        "name": "Buyer Eve", "email": "eve@test.ke",
        "password": "EvePass123!",
        "lat": -1.32, "lng": 36.82,
    })
    buyer = (await client.post("/auth/login", json={
        "phone": buyer_phone, "password": "EvePass123!",
    })).json()

    return {
        "seller_token": seller["access_token"],
        "seller_id":    seller["user_id"],
        "buyer_token":  buyer["access_token"],
        "buyer_id":     buyer["user_id"],
    }


@pytest_asyncio.fixture(scope="module")
async def listing_id(client, tokens):
    resp = await client.post("/listings/", json={
        "name": "MacBook Pro M3",
        "category": "electronics",
        "price": 220000,
        "lat": -1.3, "lng": 36.8,
    }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
    assert resp.status_code == 201
    return resp.json()["id"]


class TestDealFlow:
    deal_id: str = ""

    @pytest.mark.asyncio
    async def test_finalize_deal(self, client, tokens, listing_id):
        resp = await client.post("/deal/finalize", json={
            "listing_id":   listing_id,
            "buyer_id":     tokens["buyer_id"],
            "agreed_price": 210000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code == 201
        data = resp.json()
        assert data["agreed_price"] == 210000
        assert data["commission"] == pytest.approx(6300, rel=0.01)  # 3%
        assert data["status"] == "agreed"
        TestDealFlow.deal_id = data["deal_id"]

    @pytest.mark.asyncio
    async def test_get_deal(self, client, tokens):
        deal_id = TestDealFlow.deal_id
        resp = await client.get(f"/deal/{deal_id}",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp.status_code == 200
        assert resp.json()["id"] == deal_id

    @pytest.mark.asyncio
    async def test_only_buyer_confirms_delivery(self, client, tokens):
        """Seller should not be able to confirm delivery."""
        deal_id = TestDealFlow.deal_id
        resp = await client.post(f"/deal/{deal_id}/confirm-delivery",
            headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code in (403, 400)

    @pytest.mark.asyncio
    async def test_duplicate_deal_returns_existing(self, client, tokens, listing_id):
        """Finalizing same listing+buyer again should return existing deal."""
        resp = await client.post("/deal/finalize", json={
            "listing_id":   listing_id,
            "buyer_id":     tokens["buyer_id"],
            "agreed_price": 200000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        data = resp.json()
        # Should either 201 with existed=True or 200 — not a brand new deal
        assert data.get("existed") is True or data.get("deal_id") == TestDealFlow.deal_id
