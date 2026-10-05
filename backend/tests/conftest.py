import os
import tempfile

_tmp = tempfile.mkdtemp(prefix="mediasync-test-")
os.environ["MEDIASYNC_DATABASE_URL"] = f"sqlite+aiosqlite:///{_tmp}/test.db"
os.environ["MEDIASYNC_STORAGE_BACKEND"] = "local"
os.environ["MEDIASYNC_LOCAL_STORAGE_DIR"] = f"{_tmp}/blobs"
os.environ["MEDIASYNC_JWT_SECRET"] = "test-secret-test-secret-test-secret"

import httpx  # noqa: E402
import pytest_asyncio  # noqa: E402

from app.db import Base, engine, init_db  # noqa: E402
from app.main import app  # noqa: E402


@pytest_asyncio.fixture
async def client():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client, email="a@example.com", password="password123"):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth(tokens):
    return {"Authorization": f"Bearer {tokens['access_token']}"}
