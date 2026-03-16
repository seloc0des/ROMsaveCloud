import hashlib
import re
import shutil
import sqlite3
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, status
from fastapi.responses import FileResponse

from server.auth import get_current_user
from server.config import MAX_SAVE_SIZE_MB, MAX_VERSIONS, SAVES_DIR
from server.database import get_db
from server.models import SaveListResponse, SaveMeta

router = APIRouter(prefix="/api/saves", tags=["saves"])

# only allow safe filesystem characters — block path traversal components
SAFE_NAME = re.compile(r"^[a-zA-Z0-9_\-. ()\[\]!,&'+#]+$")


def _validate_name(value: str, field: str):
    if not SAFE_NAME.match(value):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid {field}: only alphanumeric, spaces, hyphens, underscores, dots, parens, brackets, and !,&'+# allowed",
        )
    # block "." and ".." which resolve to current/parent directory
    if value.strip() in (".", ".."):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid {field}: '.' and '..' are not allowed",
        )


def _user_save_dir(user_id: int, system_name: str, game_name: str) -> Path:
    """Build the on-disk path for a user's save directory."""
    return SAVES_DIR / str(user_id) / system_name / game_name


def _save_file_path(user_id: int, system_name: str, game_name: str, file_name: str, version: int) -> Path:
    return _user_save_dir(user_id, system_name, game_name) / f"v{version}_{file_name}"


@router.post("/upload")
def upload_save(
    file: UploadFile,
    system_name: str = Query(..., min_length=1, max_length=64),
    game_name: str = Query(..., min_length=1, max_length=128),
    file_name: Optional[str] = Query(None, min_length=1, max_length=128),
    user: dict = Depends(get_current_user),
):
    _validate_name(system_name, "system_name")
    _validate_name(game_name, "game_name")

    # read in chunks — bail early if file exceeds size limit
    max_bytes = MAX_SAVE_SIZE_MB * 1024 * 1024
    chunks = []
    size = 0
    hasher = hashlib.sha256()
    while True:
        chunk = file.file.read(65536)
        if not chunk:
            break
        size += len(chunk)
        if size > max_bytes:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"File exceeds {MAX_SAVE_SIZE_MB}MB limit",
            )
        chunks.append(chunk)
        hasher.update(chunk)

    if size == 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Empty file")

    content = b"".join(chunks)
    checksum = hasher.hexdigest()
    # prefer explicit file_name param over multipart filename (which may be a temp path)
    file_name = file_name or file.filename or "unknown.sav"
    _validate_name(file_name, "file_name")

    with get_db() as db:
        save_path = None
        max_retries = 3
        for attempt in range(max_retries):
            # get current max version for this save slot
            row = db.execute(
                """SELECT COALESCE(MAX(version), 0) as max_ver FROM saves
                   WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ?""",
                (user["id"], system_name, game_name, file_name),
            ).fetchone()
            next_version = row["max_ver"] + 1

            # skip upload if checksum matches latest version
            if next_version > 1:
                latest = db.execute(
                    """SELECT checksum FROM saves
                       WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ? AND version = ?""",
                    (user["id"], system_name, game_name, file_name, next_version - 1),
                ).fetchone()
                if latest and latest["checksum"] == checksum:
                    return {"message": "Save unchanged, skipping upload", "version": next_version - 1}

            # clean up file from previous failed attempt
            if save_path and save_path.exists():
                save_path.unlink(missing_ok=True)

            # write file to disk
            save_path = _save_file_path(user["id"], system_name, game_name, file_name, next_version)
            save_path.parent.mkdir(parents=True, exist_ok=True)
            save_path.write_bytes(content)

            try:
                db.execute(
                    """INSERT INTO saves (user_id, system_name, game_name, file_name, file_size, version, checksum)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (user["id"], system_name, game_name, file_name, size, next_version, checksum),
                )
                break  # success
            except sqlite3.IntegrityError:
                if attempt == max_retries - 1:
                    save_path.unlink(missing_ok=True)
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail="Version conflict — try again",
                    )

        # prune old versions beyond MAX_VERSIONS
        old_versions = db.execute(
            """SELECT id, version FROM saves
               WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ?
               ORDER BY version DESC""",
            (user["id"], system_name, game_name, file_name),
        ).fetchall()

        if len(old_versions) > MAX_VERSIONS:
            for row in old_versions[MAX_VERSIONS:]:
                old_path = _save_file_path(user["id"], system_name, game_name, file_name, row["version"])
                if old_path.exists():
                    old_path.unlink()
                db.execute("DELETE FROM saves WHERE id = ?", (row["id"],))

    return {"message": "Save uploaded", "version": next_version, "checksum": checksum}


@router.get("/list", response_model=SaveListResponse)
def list_saves(
    system_name: Optional[str] = Query(None),
    game_name: Optional[str] = Query(None),
    user: dict = Depends(get_current_user),
):
    query = "SELECT * FROM saves WHERE user_id = ?"
    params: list = [user["id"]]

    if system_name:
        _validate_name(system_name, "system_name")
        query += " AND system_name = ?"
        params.append(system_name)
    if game_name:
        _validate_name(game_name, "game_name")
        query += " AND game_name = ?"
        params.append(game_name)

    query += " ORDER BY system_name, game_name, file_name, version DESC"

    with get_db() as db:
        rows = db.execute(query, params).fetchall()

    saves = [
        SaveMeta(
            id=r["id"],
            system_name=r["system_name"],
            game_name=r["game_name"],
            file_name=r["file_name"],
            file_size=r["file_size"],
            version=r["version"],
            checksum=r["checksum"],
            uploaded_at=r["uploaded_at"],
        )
        for r in rows
    ]
    return SaveListResponse(saves=saves, total=len(saves))


@router.get("/download")
def download_save(
    system_name: str = Query(...),
    game_name: str = Query(...),
    file_name: str = Query(...),
    version: Optional[int] = Query(None),
    user: dict = Depends(get_current_user),
):
    _validate_name(system_name, "system_name")
    _validate_name(game_name, "game_name")
    _validate_name(file_name, "file_name")

    with get_db() as db:
        if version is not None:
            row = db.execute(
                """SELECT version FROM saves
                   WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ? AND version = ?""",
                (user["id"], system_name, game_name, file_name, version),
            ).fetchone()
        else:
            # latest version
            row = db.execute(
                """SELECT version FROM saves
                   WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ?
                   ORDER BY version DESC LIMIT 1""",
                (user["id"], system_name, game_name, file_name),
            ).fetchone()

    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Save not found")

    save_path = _save_file_path(user["id"], system_name, game_name, file_name, row["version"])
    if not save_path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Save file missing from disk")

    return FileResponse(save_path, filename=file_name, media_type="application/octet-stream")


@router.delete("/delete")
def delete_save(
    system_name: str = Query(...),
    game_name: str = Query(...),
    file_name: str = Query(...),
    version: Optional[int] = Query(None),
    user: dict = Depends(get_current_user),
):
    _validate_name(system_name, "system_name")
    _validate_name(game_name, "game_name")
    _validate_name(file_name, "file_name")

    with get_db() as db:
        if version is not None:
            rows = db.execute(
                """SELECT id, version FROM saves
                   WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ? AND version = ?""",
                (user["id"], system_name, game_name, file_name, version),
            ).fetchall()
        else:
            # delete all versions
            rows = db.execute(
                """SELECT id, version FROM saves
                   WHERE user_id = ? AND system_name = ? AND game_name = ? AND file_name = ?""",
                (user["id"], system_name, game_name, file_name),
            ).fetchall()

        if not rows:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Save not found")

        for r in rows:
            path = _save_file_path(user["id"], system_name, game_name, file_name, r["version"])
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            db.execute("DELETE FROM saves WHERE id = ?", (r["id"],))

        # clean up empty directories (verify path is actually under SAVES_DIR)
        game_dir = _user_save_dir(user["id"], system_name, game_name)
        if game_dir.exists() and not any(game_dir.iterdir()):
            resolved = game_dir.resolve()
            if resolved.is_relative_to(SAVES_DIR.resolve()):
                shutil.rmtree(game_dir, ignore_errors=True)

    deleted_count = len(rows)
    return {"message": f"Deleted {deleted_count} save(s)"}


@router.get("/systems")
def list_systems(user: dict = Depends(get_current_user)):
    """List all unique system names for this user."""
    with get_db() as db:
        rows = db.execute(
            "SELECT DISTINCT system_name FROM saves WHERE user_id = ? ORDER BY system_name",
            (user["id"],),
        ).fetchall()
    return {"systems": [r["system_name"] for r in rows]}


@router.get("/games")
def list_games(
    system_name: str = Query(...),
    user: dict = Depends(get_current_user),
):
    """List all games for a given system."""
    with get_db() as db:
        rows = db.execute(
            "SELECT DISTINCT game_name FROM saves WHERE user_id = ? AND system_name = ? ORDER BY game_name",
            (user["id"], system_name),
        ).fetchall()
    return {"games": [r["game_name"] for r in rows]}
