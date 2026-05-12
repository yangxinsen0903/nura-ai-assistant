from __future__ import annotations

from app.core.config import settings
from app.services.emotion_service import analyze_text_emotion

NEGATIVE = {"anxious", "overwhelmed", "panic", "stress", "sad", "lonely"}
MEDITATION_TRIGGERS = {"meditate", "meditation", "breathing", "calm me down", "grounding"}


def infer_mode(user_text: str, requested_mode: str | None, history: list[str]) -> str:
    text = user_text.lower()
    if requested_mode in {"chat", "meditation"}:
        return requested_mode

    if any(k in text for k in MEDITATION_TRIGGERS):
        return "meditation"

    recent = " ".join(history[-4:]).lower()
    if "guided meditation" in recent or "breathing" in recent:
        return "meditation"

    return "chat"


def _fallback_reply(user_text: str, emotion: str, risk_level: str, mode: str) -> str:
    if risk_level == "high":
        return (
            "I hear that you're in intense distress. You're not alone right now. "
            "If you might hurt yourself, please contact local emergency services or a crisis hotline immediately."
        )

    if mode == "meditation":
        return (
            "Let’s do a short guided reset. Step 1: sit comfortably and place one hand on your chest. "
            "Step 2: inhale through your nose for 4 counts. Step 3: exhale slowly for 6 counts. "
            "Repeat this for 5 rounds. Tell me when you're done and I’ll guide the next step."
        )

    if emotion == "anxious":
        return "I’m here with you. Let’s slow your nervous system first: inhale 4, exhale 6, for 3 rounds. What feels heaviest right now?"
    if emotion == "calm":
        return "You’re sounding steadier. Nice work. Do you want a quick reflection, or a small plan for the next hour?"
    return "I’m listening. Start with the one thing that feels most important right now."


def _build_system_prompt(mode: str) -> str:
    base = (
        "You are Nura.ai, an empathetic AI therapist-style support assistant. "
        "Never claim to be a licensed clinician. Do not diagnose. Be warm, concise, and practical. "
        "If self-harm risk appears, prioritize immediate emergency guidance. "
        "Keep replies under 120 words unless user asks for more."
    )

    if mode == "meditation":
        return (
            base
            + " User requested guided meditation. Stay in guided meditation mode. "
            "Use step-by-step instructions (one clear step per turn), with breath counts and grounding cues. "
            "Do not switch topics unless user asks."
        )

    return base


def generate_reply(user_text: str, history: list[str], requested_mode: str | None = None) -> tuple[str, str, str, str]:
    emotion, _score, risk_level = analyze_text_emotion(user_text)
    mode = infer_mode(user_text, requested_mode, history)

    if not settings.openai_api_key:
        return _fallback_reply(user_text, emotion, risk_level, mode), emotion, risk_level, mode

    try:
        from openai import OpenAI

        client = OpenAI(api_key=settings.openai_api_key)
        system_prompt = _build_system_prompt(mode)

        messages = [{"role": "system", "content": system_prompt}]
        for item in history[-8:]:
            role, content = item.split(":", 1)
            messages.append({"role": role, "content": content.strip()})
        messages.append({"role": "user", "content": user_text})

        resp = client.chat.completions.create(
            model=settings.openai_model,
            messages=messages,
            temperature=0.5,
            max_tokens=180,
        )

        text = resp.choices[0].message.content or _fallback_reply(user_text, emotion, risk_level, mode)
        return text.strip(), emotion, risk_level, mode
    except Exception:
        return _fallback_reply(user_text, emotion, risk_level, mode), emotion, risk_level, mode
