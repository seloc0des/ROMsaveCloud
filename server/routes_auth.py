from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse

from server.auth import COOKIE_NAME, create_access_token, get_current_user, hash_password, verify_password
from server.config import ACCESS_TOKEN_EXPIRE_MINUTES
from server.database import get_db
from server.models import TokenResponse, UserLogin, UserRegister
from server.ratelimit import auth_limiter

router = APIRouter(prefix="/api/auth", tags=["auth"])


def _rate_limit(request: Request):
    auth_limiter.check(request)


def _set_token_cookie(response: JSONResponse, token: str):
    """Set the JWT as an httpOnly cookie for web UI clients."""
    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        httponly=True,
        samesite="lax",
        max_age=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        path="/",
        # secure=True should be enabled when served over HTTPS
    )


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED,
              dependencies=[Depends(_rate_limit)])
def register(body: UserRegister):
    with get_db() as db:
        existing = db.execute("SELECT id FROM users WHERE username = ?", (body.username,)).fetchone()
        if existing:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Username already taken")

        pw_hash = hash_password(body.password)
        cursor = db.execute(
            "INSERT INTO users (username, password_hash) VALUES (?, ?)",
            (body.username, pw_hash),
        )
        user_id = cursor.lastrowid

    token = create_access_token(user_id, body.username)
    response = JSONResponse(
        content=TokenResponse(access_token=token).model_dump(),
        status_code=status.HTTP_201_CREATED,
    )
    _set_token_cookie(response, token)
    return response


@router.post("/login", response_model=TokenResponse,
              dependencies=[Depends(_rate_limit)])
def login(body: UserLogin):
    with get_db() as db:
        row = db.execute(
            "SELECT id, username, password_hash FROM users WHERE username = ?",
            (body.username,),
        ).fetchone()

    if row:
        password_valid = verify_password(body.password, row["password_hash"])
    else:
        # constant-time: always hash to prevent username enumeration via timing
        hash_password(body.password)
        password_valid = False

    if not password_valid:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    token = create_access_token(row["id"], row["username"])
    response = JSONResponse(
        content=TokenResponse(access_token=token).model_dump(),
    )
    _set_token_cookie(response, token)
    return response


@router.get("/me")
def me(user: dict = Depends(get_current_user)):
    return {"username": user["username"]}


@router.post("/logout")
def logout():
    response = JSONResponse(content={"message": "Logged out"})
    response.delete_cookie(key=COOKIE_NAME, path="/")
    return response
