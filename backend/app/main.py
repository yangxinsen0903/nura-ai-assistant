from fastapi import FastAPI

from app.api.v1.auth import router as auth_router
from app.api.v1.chat import router as chat_router
from app.api.v1.emotion import router as emotion_router
from app.api.v1.health import router as health_router
from app.core.config import settings
from app.core.db import Base, engine
import app.models  # noqa: F401

app = FastAPI(title=settings.app_name)

Base.metadata.create_all(bind=engine)

app.include_router(health_router)
app.include_router(auth_router, prefix=settings.api_v1_prefix)
app.include_router(chat_router, prefix=settings.api_v1_prefix)
app.include_router(emotion_router, prefix=settings.api_v1_prefix)
