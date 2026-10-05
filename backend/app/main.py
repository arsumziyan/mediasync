from contextlib import asynccontextmanager

from fastapi import FastAPI

from .db import init_db
from .routers import assets, auth, sync


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="MediaSync API", version="1.0.0", lifespan=lifespan)
app.include_router(auth.router)
app.include_router(assets.router)
app.include_router(sync.router)


@app.get("/health", tags=["meta"])
async def health():
    return {"status": "ok"}
