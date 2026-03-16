from typing import List

from pydantic import BaseModel, Field


class UserRegister(BaseModel):
    username: str = Field(..., min_length=3, max_length=32, pattern=r"^[a-zA-Z0-9_-]+$")
    password: str = Field(..., min_length=8, max_length=128)


class UserLogin(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class SaveMeta(BaseModel):
    id: int
    system_name: str
    game_name: str
    file_name: str
    file_size: int
    version: int
    checksum: str
    uploaded_at: str


class SaveListResponse(BaseModel):
    saves: List[SaveMeta]
    total: int
