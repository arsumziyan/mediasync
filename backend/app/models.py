import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, BigInteger, Boolean, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def new_id() -> str:
    return str(uuid.uuid4())


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # Monotonic per-user change counter. Every asset mutation bumps it and
    # stamps the new value on the asset, which gives clients a simple delta cursor.
    rev: Mapped[int] = mapped_column(Integer, default=0)

    assets: Mapped[list["Asset"]] = relationship(back_populates="user")


class Asset(Base):
    __tablename__ = "assets"

    # Client-generated UUID so uploads/creates are idempotent and work offline.
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)

    kind: Mapped[str] = mapped_column(String(16))  # photo | video | audio | text
    filename: Mapped[str] = mapped_column(String(255))
    content_type: Mapped[str] = mapped_column(String(128), default="application/octet-stream")

    # Metadata produced by on-device ML (plaintext by design; media itself is E2E encrypted).
    tags: Mapped[list] = mapped_column(JSON, default=list)
    sentiment: Mapped[str | None] = mapped_column(String(16), nullable=True)
    extra: Mapped[dict] = mapped_column(JSON, default=dict)

    # Blob state
    object_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    size: Mapped[int] = mapped_column(BigInteger, default=0)
    sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    uploaded: Mapped[bool] = mapped_column(Boolean, default=False)

    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    rev: Mapped[int] = mapped_column(Integer, default=0, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    user: Mapped[User] = relationship(back_populates="assets")
