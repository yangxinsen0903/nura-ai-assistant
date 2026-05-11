from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.models.chat import ChatMessage
from app.schemas.chat import ChatMessageRequest, ChatMessageResponse
from app.services.assistant_service import generate_reply

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("/message", response_model=ChatMessageResponse)
def send_message(payload: ChatMessageRequest, db: Session = Depends(get_db)):
    db.add(ChatMessage(user_id=payload.user_id, role="user", content=payload.content))

    reply, emotion, risk_level = generate_reply(payload.content)

    db.add(ChatMessage(user_id=payload.user_id, role="assistant", content=reply, emotion=emotion))
    db.commit()

    return ChatMessageResponse(reply=reply, emotion=emotion, risk_level=risk_level)
