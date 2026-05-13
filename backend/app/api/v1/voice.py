from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from io import BytesIO

from app.core.config import settings

router = APIRouter(prefix="/voice", tags=["voice"])


@router.post("/tts")
def tts(text: str = Form(...), style: str = Form("warm_female"), speed: float = Form(0.9)):
    if not settings.openai_api_key:
        raise HTTPException(status_code=503, detail="TTS unavailable")

    try:
        from openai import OpenAI

        client = OpenAI(api_key=settings.openai_api_key)
        voice = "alloy"
        if style == "warm_female":
            voice = "nova"

        safe_speed = max(0.75, min(1.05, speed))
        audio = client.audio.speech.create(
            model="gpt-4o-mini-tts",
            voice=voice,
            input=text,
            response_format="mp3",
            speed=safe_speed,
        )
        data = audio.read()
        return StreamingResponse(BytesIO(data), media_type="audio/mpeg")
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"TTS failed: {e}")


@router.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    if not settings.openai_api_key:
        raise HTTPException(status_code=503, detail="Transcribe unavailable")

    try:
        from openai import OpenAI

        client = OpenAI(api_key=settings.openai_api_key)
        data = await file.read()
        transcript = client.audio.transcriptions.create(
            model="gpt-4o-mini-transcribe",
            file=(file.filename or "audio.m4a", data, file.content_type or "audio/m4a"),
        )
        text = (getattr(transcript, "text", "") or "").strip()
        return {"text": text}
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Transcribe failed: {e}")
