from pydantic import BaseModel


class AnonymousLoginRequest(BaseModel):
    device_id: str
    nickname: str | None = None


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: int
