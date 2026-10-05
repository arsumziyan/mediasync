from datetime import datetime, timezone
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, EmailStr, Field


def _ensure_utc(v: datetime) -> datetime:
    return v.replace(tzinfo=timezone.utc) if v.tzinfo is None else v


UTCDateTime = Annotated[datetime, AfterValidator(_ensure_utc)]


class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


Kind = Literal["photo", "video", "audio", "text"]
Sentiment = Literal["positive", "neutral", "negative"]


class AssetUpsert(BaseModel):
    kind: Kind
    filename: str = Field(max_length=255)
    content_type: str = "application/octet-stream"
    tags: list[str] = Field(default_factory=list, max_length=64)
    sentiment: Sentiment | None = None
    extra: dict = Field(default_factory=dict)
    created_at: UTCDateTime | None = None


class AssetOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    kind: Kind
    filename: str
    content_type: str
    tags: list[str]
    sentiment: Sentiment | None
    extra: dict
    size: int
    sha256: str | None
    uploaded: bool
    deleted: bool
    rev: int
    created_at: UTCDateTime
    updated_at: UTCDateTime


class SyncResponse(BaseModel):
    changes: list[AssetOut]
    cursor: int  # pass back as ?since= on the next call
    has_more: bool
