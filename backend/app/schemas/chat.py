from pydantic import BaseModel


class ChatMessageRequest(BaseModel):
    user_id: int
    content: str


class ChatMessageResponse(BaseModel):
    reply: str
    emotion: str
    risk_level: str
