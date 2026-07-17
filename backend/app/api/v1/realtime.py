import asyncio
import json

import websockets
from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.core.config import settings
from app.services.assistant_service import _build_system_prompt

router = APIRouter(prefix="/realtime", tags=["realtime"])

_OPENAI_URL = "wss://api.openai.com/v1/realtime?model=gpt-realtime-2"


@router.websocket("/ws")
async def realtime_ws(
    client_ws: WebSocket,
    first_name: str = Query(default=""),
):
    await client_ws.accept()

    if not settings.openai_api_key:
        await client_ws.close(code=1011, reason="OpenAI API key not configured")
        return

    system_prompt = _build_system_prompt(
        mode="chat",
        emotion="neutral",
        source="voice",
        first_name=first_name or None,
    )

    # OpenAI Realtime API is now GA — no OpenAI-Beta header needed
    oai_headers = {
        "Authorization": f"Bearer {settings.openai_api_key}",
    }

    try:
        async with websockets.connect(
            _OPENAI_URL,
            additional_headers=oai_headers,
            ping_interval=20,
        ) as oai_ws:
            # Configure session immediately after connecting
            session_update = {
                "type": "session.update",
                "session": {
                    "modalities": ["audio", "text"],
                    "instructions": system_prompt,
                    "voice": "nova",
                    "input_audio_format": "pcm16",
                    "output_audio_format": "pcm16",
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 700,
                    },
                    "temperature": 0.7,
                    "max_response_output_tokens": 150,
                },
            }
            await oai_ws.send(json.dumps(session_update))

            async def from_client() -> None:
                try:
                    while True:
                        msg = await client_ws.receive_text()
                        await oai_ws.send(msg)
                except (WebSocketDisconnect, Exception):
                    pass

            async def from_openai() -> None:
                try:
                    async for raw in oai_ws:
                        text = raw if isinstance(raw, str) else raw.decode()
                        try:
                            await client_ws.send_text(text)
                        except Exception:
                            return
                except Exception:
                    pass

            await asyncio.gather(from_client(), from_openai())

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        try:
            await client_ws.close(code=1011, reason=str(exc))
        except Exception:
            pass
