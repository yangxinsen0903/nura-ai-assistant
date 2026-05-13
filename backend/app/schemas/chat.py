from pydantic import BaseModel


class ChatMessageRequest(BaseModel):
    user_id: int
    content: str
    mode: str | None = None  # chat | meditation
    source: str | None = None  # text | voice


class ChatMessageResponse(BaseModel):
    reply: str
    emotion: str
    risk_level: str
    mode: str
