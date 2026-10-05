import hashlib
import uuid

from conftest import auth, register

META = {"kind": "photo", "filename": "beach.jpg", "content_type": "image/jpeg", "tags": ["beach", "sunset"]}


# ---------- auth ----------
async def test_register_login_refresh(client):
    tokens = await register(client)
    assert tokens["token_type"] == "bearer"

    dup = await client.post("/auth/register", json={"email": "A@example.com", "password": "password123"})
    assert dup.status_code == 409

    bad = await client.post("/auth/login", json={"email": "a@example.com", "password": "wrong-password"})
    assert bad.status_code == 401
    ok = await client.post("/auth/login", json={"email": "a@example.com", "password": "password123"})
    assert ok.status_code == 200

    r = await client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert r.status_code == 200
    # access token must not be accepted as a refresh token, and vice versa
    assert (await client.post("/auth/refresh", json={"refresh_token": tokens["access_token"]})).status_code == 401
    r = await client.get("/assets", headers={"Authorization": f"Bearer {tokens['refresh_token']}"})
    assert r.status_code == 401


async def test_requires_auth(client):
    assert (await client.get("/assets")).status_code == 401
    assert (await client.get("/sync/changes")).status_code == 401
    assert (await client.get("/assets", headers={"Authorization": "Bearer junk"})).status_code == 401


# ---------- assets ----------
async def test_upsert_is_idempotent_and_updates(client):
    h = auth(await register(client))
    aid = str(uuid.uuid4())

    r1 = await client.put(f"/assets/{aid}", json=META, headers=h)
    assert r1.status_code == 200 and r1.json()["rev"] == 1
    r2 = await client.put(f"/assets/{aid}", json={**META, "tags": ["beach"], "sentiment": "positive"}, headers=h)
    assert r2.json()["tags"] == ["beach"] and r2.json()["sentiment"] == "positive"
    assert r2.json()["rev"] == 2

    assert len((await client.get("/assets", headers=h)).json()) == 1
    assert (await client.put("/assets/not-a-uuid", json=META, headers=h)).status_code == 422


async def test_upload_download_roundtrip_with_checksum(client):
    h = auth(await register(client))
    aid = str(uuid.uuid4())
    await client.put(f"/assets/{aid}", json=META, headers=h)

    blob = b"\x00\x01ciphertext" * 5000
    digest = hashlib.sha256(blob).hexdigest()

    bad = await client.put(f"/assets/{aid}/content", content=blob,
                           headers={**h, "X-Content-SHA256": "0" * 64, "Content-Type": "application/octet-stream"})
    assert bad.status_code == 422
    assert (await client.get(f"/assets/{aid}/content", headers=h)).status_code == 404  # nothing stored

    ok = await client.put(f"/assets/{aid}/content", content=blob,
                          headers={**h, "X-Content-SHA256": digest, "Content-Type": "application/octet-stream"})
    assert ok.status_code == 200
    body = ok.json()
    assert body["uploaded"] is True and body["size"] == len(blob) and body["sha256"] == digest

    dl = await client.get(f"/assets/{aid}/content", headers=h)
    assert dl.status_code == 200 and dl.content == blob


async def test_users_are_isolated(client):
    a = auth(await register(client, "a@example.com"))
    b = auth(await register(client, "b@example.com"))
    aid = str(uuid.uuid4())
    await client.put(f"/assets/{aid}", json=META, headers=a)
    await client.put(f"/assets/{aid}/content", content=b"secret", headers=a)

    assert (await client.get(f"/assets/{aid}/content", headers=b)).status_code == 404
    assert (await client.delete(f"/assets/{aid}", headers=b)).status_code == 404
    assert (await client.put(f"/assets/{aid}", json=META, headers=b)).status_code == 409
    assert (await client.get("/assets", headers=b)).json() == []
    assert (await client.get("/sync/changes", headers=b)).json()["changes"] == []


# ---------- sync ----------
async def test_delta_sync_with_cursor_pagination_and_tombstones(client):
    h = auth(await register(client))
    ids = [str(uuid.uuid4()) for _ in range(3)]
    for i, aid in enumerate(ids):
        await client.put(f"/assets/{aid}", json={**META, "filename": f"{i}.jpg"}, headers=h)

    page1 = (await client.get("/sync/changes?since=0&limit=2", headers=h)).json()
    assert len(page1["changes"]) == 2 and page1["has_more"] is True
    page2 = (await client.get(f"/sync/changes?since={page1['cursor']}&limit=2", headers=h)).json()
    assert len(page2["changes"]) == 1 and page2["has_more"] is False
    cursor = page2["cursor"]

    # nothing new
    idle = (await client.get(f"/sync/changes?since={cursor}", headers=h)).json()
    assert idle["changes"] == [] and idle["cursor"] == cursor

    # delete one -> shows up as a tombstone and disappears from the list
    await client.put(f"/assets/{ids[0]}/content", content=b"x", headers=h)
    cursor = (await client.get(f"/sync/changes?since={cursor}", headers=h)).json()["cursor"]
    assert (await client.delete(f"/assets/{ids[0]}", headers=h)).status_code == 204
    delta = (await client.get(f"/sync/changes?since={cursor}", headers=h)).json()
    assert [c["id"] for c in delta["changes"]] == [ids[0]]
    assert delta["changes"][0]["deleted"] is True and delta["changes"][0]["uploaded"] is False
    assert len((await client.get("/assets", headers=h)).json()) == 2
    assert (await client.get(f"/assets/{ids[0]}/content", headers=h)).status_code == 404
