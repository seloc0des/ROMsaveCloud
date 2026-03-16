import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pathlib import Path

from server.database import init_db
from server.routes_auth import router as auth_router
from server.routes_saves import router as saves_router


@asynccontextmanager
async def lifespan(app):
    init_db()
    yield


app = FastAPI(
    title="OSGSameCloudService",
    description="Open source RetroArch game save cloud backup service",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS — if OSGSC_CORS_ORIGINS is set, restrict to those origins with credentials.
# Otherwise allow all origins without credentials (fine for Bearer token auth).
_cors_origins = os.getenv("OSGSC_CORS_ORIGINS", "")
if _cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip() for o in _cors_origins.split(",")],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )


@app.get("/api/health")
def health():
    return {"status": "ok"}


# routers must be registered before the catch-all static mount
app.include_router(auth_router)
app.include_router(saves_router)

# serve the web UI — must be last since it catches all unmatched paths
web_dir = Path(__file__).parent.parent / "web"
if web_dir.exists():
    app.mount("/", StaticFiles(directory=str(web_dir), html=True), name="web")
