"""Blob storage abstraction. Blobs are opaque (client-side encrypted) bytes."""
import asyncio
import hashlib
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Protocol

from .config import get_settings


class Storage(Protocol):
    async def put(self, key: str, chunks: AsyncIterator[bytes], content_type: str) -> tuple[int, str]:
        """Store the stream. Returns (size_bytes, sha256_hex)."""

    async def get(self, key: str) -> AsyncIterator[bytes]: ...

    async def delete(self, key: str) -> None: ...


class LocalStorage:
    def __init__(self, root: str):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        p = (self.root / key).resolve()
        if self.root.resolve() not in p.parents:
            raise ValueError("invalid key")
        return p

    async def put(self, key, chunks, content_type):
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        h, size = hashlib.sha256(), 0
        with path.open("wb") as f:
            async for chunk in chunks:
                f.write(chunk)
                h.update(chunk)
                size += len(chunk)
        return size, h.hexdigest()

    async def get(self, key):
        path = self._path(key)
        with path.open("rb") as f:
            while chunk := f.read(1024 * 256):
                yield chunk

    async def delete(self, key):
        self._path(key).unlink(missing_ok=True)


class S3Storage:
    """S3 / MinIO via boto3 (blocking calls pushed to a thread).

    The upload is spooled to a temp file while hashing, then sent with upload_fileobj
    (which handles multipart automatically for large files).
    """

    def __init__(self):
        import boto3

        s = get_settings()
        self.bucket = s.s3_bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=s.s3_endpoint_url,
            region_name=s.s3_region,
            aws_access_key_id=s.s3_access_key,
            aws_secret_access_key=s.s3_secret_key,
        )

    def ensure_bucket(self) -> None:
        try:
            self.client.head_bucket(Bucket=self.bucket)
        except Exception:
            self.client.create_bucket(Bucket=self.bucket)

    async def put(self, key, chunks, content_type):
        import tempfile

        h, size = hashlib.sha256(), 0
        with tempfile.SpooledTemporaryFile(max_size=16 * 1024 * 1024) as tmp:
            async for chunk in chunks:
                tmp.write(chunk)
                h.update(chunk)
                size += len(chunk)
            tmp.seek(0)
            await asyncio.to_thread(
                self.client.upload_fileobj, tmp, self.bucket, key, ExtraArgs={"ContentType": content_type}
            )
        return size, h.hexdigest()

    async def get(self, key):
        obj = await asyncio.to_thread(self.client.get_object, Bucket=self.bucket, Key=key)
        body = obj["Body"]
        while True:
            chunk = await asyncio.to_thread(body.read, 1024 * 256)
            if not chunk:
                break
            yield chunk

    async def delete(self, key):
        await asyncio.to_thread(self.client.delete_object, Bucket=self.bucket, Key=key)


_storage: Storage | None = None


def get_storage() -> Storage:
    global _storage
    if _storage is None:
        s = get_settings()
        if s.storage_backend == "local":
            _storage = LocalStorage(s.local_storage_dir)
        else:
            st = S3Storage()
            st.ensure_bucket()
            _storage = st
    return _storage
