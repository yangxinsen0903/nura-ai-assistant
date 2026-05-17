from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.models.chat import ChatMessage
from app.models.user import User
from app.schemas.chat import ChatMessageRequest, ChatMessageResponse
from app.services.assistant_service import generate_reply

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("/message", response_model=ChatMessageResponse)
def send_message(payload: ChatMessageRequest, db: Session = Depends(get_db)):
    db.add(ChatMessage(user_id=payload.user_id, role="user", content=payload.content))

    history_rows = (
        db.query(ChatMessage)
        .filter(ChatMessage.user_id == payload.user_id)
        .order_by(ChatMessage.created_at.asc())
        .all()
    )
    history = [f"{m.role}:{m.content}" for m in history_rows]

    user = db.query(User).filter(User.id == payload.user_id).first()
    first_name = None
    if user and user.name:
        first_name = user.name.strip().split(" ")[0]

    reply, emotion, risk_level, mode = generate_reply(
        user_id=payload.user_id,
        user_text=payload.content,
        history=history,
        requested_mode=payload.mode,
        source=payload.source,
        first_name=first_name,
    )

    db.add(ChatMessage(user_id=payload.user_id, role="assistant", content=reply, emotion=emotion))
    db.commit()

    return ChatMessageResponse(reply=reply, emotion=emotion, risk_level=risk_level, mode=mode)
