from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import current_user
from ..models import Asset, User
from ..schemas import SyncResponse

router = APIRouter(prefix="/sync", tags=["sync"])


@router.get("/changes", response_model=SyncResponse)
async def changes(
    since: int = Query(0, ge=0, description="Cursor returned by the previous call (0 for a full sync)"),
    limit: int = Query(200, ge=1, le=1000),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    """Delta sync: every asset (including deletion tombstones) changed after `since`, oldest first."""
    rows = (
        await session.execute(
            select(Asset)
            .where(Asset.user_id == user.id, Asset.rev > since)
            .order_by(Asset.rev)
            .limit(limit + 1)
        )
    ).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    cursor = rows[-1].rev if rows else since
    return SyncResponse(changes=rows, cursor=cursor, has_more=has_more)
