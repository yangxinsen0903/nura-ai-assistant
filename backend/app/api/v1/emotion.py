from fastapi import APIRouter

from app.schemas.emotion import EmotionAnalyzeRequest, EmotionAnalyzeResponse
from app.services.emotion_service import analyze_text_emotion

router = APIRouter(prefix="/emotion", tags=["emotion"])


@router.post("/analyze", response_model=EmotionAnalyzeResponse)
def analyze(payload: EmotionAnalyzeRequest):
    emotion, score, risk = analyze_text_emotion(payload.text)
    return EmotionAnalyzeResponse(emotion=emotion, score=score, risk_level=risk)
