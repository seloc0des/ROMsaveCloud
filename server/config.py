import os
import secrets
import sys
from pathlib import Path

# paths
BASE_DIR = Path(os.getenv("OSGSC_DATA_DIR", "./data"))
SAVES_DIR = BASE_DIR / "saves"
DB_PATH = BASE_DIR / "db" / "osgsc.db"

# auth — generate a random key if none set, but warn loudly
_default_secret = os.getenv("OSGSC_SECRET_KEY", "")
if not _default_secret:
    _default_secret = secrets.token_hex(32)
    print(
        "WARNING: OSGSC_SECRET_KEY not set — using a random key. "
        "Tokens will be invalidated on restart. Set OSGSC_SECRET_KEY in your .env file.",
        file=sys.stderr,
    )
SECRET_KEY = _default_secret
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("OSGSC_TOKEN_EXPIRE_MINUTES", "1440"))  # 24h default
ALGORITHM = "HS256"

# saves
MAX_SAVE_SIZE_MB = max(1, int(os.getenv("OSGSC_MAX_SAVE_SIZE_MB", "50")))
MAX_VERSIONS = max(1, int(os.getenv("OSGSC_MAX_VERSIONS", "5")))

# server
HOST = os.getenv("OSGSC_HOST", "0.0.0.0")
PORT = int(os.getenv("OSGSC_PORT", "4444"))
