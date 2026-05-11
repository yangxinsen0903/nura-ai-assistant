from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.auth import create_access_token
from app.core.db import get_db
from app.models.user import User
from app.schemas.auth import AnonymousLoginRequest, TokenResponse

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/anonymous", response_model=TokenResponse)
def anonymous_login(payload: AnonymousLoginRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.external_id == payload.device_id).first()
    if not user:
        user = User(external_id=payload.device_id, nickname=payload.nickname)
        db.add(user)
        db.commit()
        db.refresh(user)

    token = create_access_token(user.id)
    return TokenResponse(access_token=token, user_id=user.id)
