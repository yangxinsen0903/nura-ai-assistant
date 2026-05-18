from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from io import BytesIO
import os
import subprocess
import tempfile

from app.core.config import settings

router = APIRouter(prefix="/voice", tags=["voice"])


def _amplify_mp3(data: bytes, gain_db: float = 9.0) -> bytes:
    """Amplify and normalize TTS audio to improve perceived loudness on iOS speaker output."""
    in_path = None
    out_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3") as in_file:
            in_file.write(data)
            in_path = in_file.name
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3") as out_file:
            out_path = out_file.name

        af = f"loudnorm=I=-16:TP=-1.5:LRA=11,volume={gain_db}dB,alimiter=limit=0.95"
        cmd = [
            "ffmpeg", "-y", "-i", in_path,
            "-af", af,
            "-codec:a", "libmp3lame", "-q:a", "2",
            out_path,
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        with open(out_path, "rb") as f:
            return f.read()
    except Exception:
        return data
    finally:
        if in_path and os.path.exists(in_path):
            os.remove(in_path)
        if out_path and os.path.exists(out_path):
            os.remove(out_path)


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
        louder = _amplify_mp3(data, gain_db=9.0)
        return StreamingResponse(BytesIO(louder), media_type="audio/mpeg")
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
