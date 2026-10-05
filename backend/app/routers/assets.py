import uuid
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..deps import current_user
from ..models import Asset, User, utcnow
from ..schemas import AssetOut, AssetUpsert
from ..storage import Storage, get_storage

router = APIRouter(prefix="/assets", tags=["assets"])


def _validate_id(asset_id: str) -> str:
    try:
        return str(uuid.UUID(asset_id))
    except ValueError:
        raise HTTPException(422, "Asset id must be a UUID")


async def _bump_rev(session: AsyncSession, user_id: str) -> int:
    """Atomically increments and returns the user's change counter."""
    result = await session.execute(
        update(User).where(User.id == user_id).values(rev=User.rev + 1).returning(User.rev)
    )
    return result.scalar_one()


async def _owned_asset(session: AsyncSession, user: User, asset_id: str) -> Asset:
    asset = await session.get(Asset, asset_id)
    if asset is None or asset.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Asset not found")
    return asset


@router.get("", response_model=list[AssetOut])
async def list_assets(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    rows = await session.execute(
        select(Asset).where(Asset.user_id == user.id, Asset.deleted.is_(False)).order_by(Asset.created_at.desc())
    )
    return rows.scalars().all()


@router.put("/{asset_id}", response_model=AssetOut)
async def upsert_asset(
    asset_id: str,
    body: AssetUpsert,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    """Idempotent create/update of asset metadata (client supplies the UUID)."""
    asset_id = _validate_id(asset_id)
    asset = await session.get(Asset, asset_id)
    if asset is not None and asset.user_id != user.id:
        raise HTTPException(status.HTTP_409_CONFLICT, "Asset id already in use")

    rev = await _bump_rev(session, user.id)
    if asset is None:
        asset = Asset(id=asset_id, user_id=user.id, created_at=body.created_at or utcnow())
        session.add(asset)
    asset.kind = body.kind
    asset.filename = body.filename
    asset.content_type = body.content_type
    asset.tags = body.tags
    asset.sentiment = body.sentiment
    asset.extra = body.extra
    asset.deleted = False
    asset.rev = rev
    asset.updated_at = utcnow()
    await session.commit()
    return asset


async def _limited(request: Request, limit: int) -> AsyncIterator[bytes]:
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Upload too large")
        yield chunk


@router.put("/{asset_id}/content", response_model=AssetOut)
async def upload_content(
    asset_id: str,
    request: Request,
    x_content_sha256: str | None = Header(default=None),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
    storage: Storage = Depends(get_storage),
):
    """Upload the (client-side encrypted) blob as the raw request body."""
    asset = await _owned_asset(session, user, _validate_id(asset_id))
    key = f"{user.id}/{asset.id}"
    content_type = request.headers.get("content-type", "application/octet-stream")

    try:
        size, digest = await storage.put(key, _limited(request, get_settings().max_upload_bytes), content_type)
    except HTTPException:
        await storage.delete(key)
        raise
    if x_content_sha256 and x_content_sha256.lower() != digest:
        await storage.delete(key)
        raise HTTPException(422, "Checksum mismatch")

    asset.object_key = key
    asset.size = size
    asset.sha256 = digest
    asset.uploaded = True
    asset.rev = await _bump_rev(session, user.id)
    asset.updated_at = utcnow()
    await session.commit()
    return asset


@router.get("/{asset_id}/content")
async def download_content(
    asset_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
    storage: Storage = Depends(get_storage),
):
    asset = await _owned_asset(session, user, _validate_id(asset_id))
    if asset.deleted or not asset.uploaded or not asset.object_key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No content for this asset")
    return StreamingResponse(
        storage.get(asset.object_key),
        media_type="application/octet-stream",
        headers={"Content-Length": str(asset.size), "X-Content-SHA256": asset.sha256 or ""},
    )


@router.delete("/{asset_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_asset(
    asset_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
    storage: Storage = Depends(get_storage),
):
    """Soft-delete (tombstone) so other devices learn about it via /sync/changes; blob is purged."""
    asset = await _owned_asset(session, user, _validate_id(asset_id))
    if asset.object_key:
        await storage.delete(asset.object_key)
    asset.deleted = True
    asset.uploaded = False
    asset.object_key = None
    asset.rev = await _bump_rev(session, user.id)
    asset.updated_at = utcnow()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
