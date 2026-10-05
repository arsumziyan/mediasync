from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="MEDIASYNC_", extra="ignore")

    # Database: use postgresql+asyncpg://... for Postgres / Supabase
    database_url: str = "sqlite+aiosqlite:///./mediasync.db"

    # JWT
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 30
    refresh_token_days: int = 30

    # Object storage (S3 / MinIO). storage_backend: "s3" or "local"
    storage_backend: str = "s3"
    s3_endpoint_url: str | None = "http://localhost:9000"
    s3_region: str = "us-east-1"
    s3_bucket: str = "mediasync"
    s3_access_key: str = "minioadmin"
    s3_secret_key: str = "minioadmin"
    local_storage_dir: str = "./.storage"

    # Limits
    max_upload_bytes: int = 512 * 1024 * 1024


@lru_cache
def get_settings() -> Settings:
    return Settings()
