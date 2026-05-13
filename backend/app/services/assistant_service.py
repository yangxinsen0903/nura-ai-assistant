from __future__ import annotations

from dataclasses import dataclass

from app.core.config import settings
from app.services.emotion_service import analyze_text_emotion

NEGATIVE = {"anxious", "overwhelmed", "panic", "stress", "sad", "lonely"}
MEDITATION_TRIGGERS = {"meditate", "meditation", "breathing", "calm me down", "grounding"}
CONFIRM_WORDS = {"ready", "next", "done", "yes", "continue", "ok", "go"}


@dataclass
class MeditationState:
    step_index: int = 0
    awaiting_confirmation: bool = False


_meditation_sessions: dict[int, MeditationState] = {}

_MEDITATION_STEPS = [
    "Step 1: Sit comfortably, relax your shoulders, and place one hand on your chest and one on your belly. Say 'ready' when you're settled.",
    "Step 2: Breathe in through your nose for 4 counts, then out gently for 6 counts. Do 4 rounds now. Tell me 'next' when done.",
    "Step 3: Keep breathing slowly and do a short body scan from forehead to jaw, neck, and shoulders. Release tension on each exhale. Say 'next' when ready.",
    "Step 4: Place both feet on the floor and name 3 things you can feel right now. Stay with each sensation for one breath. Tell me 'next' when done.",
    "Step 5: One final round: inhale calm, exhale worry for 5 breaths. When finished, say how your body feels in one sentence.",
]


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
        return _MEDITATION_STEPS[0]

    if emotion == "anxious":
        return "I’m here with you. Let’s slow down together: inhale 4, exhale 6, for 3 rounds. What feels heaviest right now?"
    if emotion == "calm":
        return "You’re sounding steadier. Nice work. Do you want a short reflection or a gentle plan for the next hour?"
    return "I’m listening. Start with the one thing that feels most important right now."


def _build_system_prompt(mode: str, emotion: str, source: str | None = None) -> str:
    pace = "Use short lines with calm rhythm and natural pauses."
    if emotion in {"anxious", "high_distress"}:
        pace = "Use extra calm, slower pacing. Keep each sentence short and soothing with brief pauses."

    brevity = "Keep replies under 90 words unless user asks for more."
    if source == "voice":
        brevity = "For voice chat, keep replies under 55 words, one clear idea at a time."

    base = (
        "You are Nura.ai, an empathetic emotional support assistant. "
        "Never claim to be a licensed clinician. Do not diagnose. Be warm, concise, and practical. "
        "If self-harm risk appears, prioritize immediate emergency guidance. "
        + brevity + " " + pace
    )

    if mode == "meditation":
        return (
            base
            + " Stay in guided meditation mode and only guide one step per turn. "
            "Never dump all steps in one answer. Wait for explicit user confirmation before moving on."
        )

    return base


def _is_confirmation(text: str) -> bool:
    lower = text.lower()
    return any(word in lower for word in CONFIRM_WORDS)


def _meditation_reply(user_id: int, user_text: str, risk_level: str) -> str:
    if risk_level == "high":
        return (
            "Before we continue, your safety comes first. Please contact local emergency services or a crisis hotline now. "
            "If you can, reach out to someone you trust and stay with them."
        )

    state = _meditation_sessions.get(user_id)
    if not state:
        state = MeditationState(step_index=0, awaiting_confirmation=True)
        _meditation_sessions[user_id] = state
        return _MEDITATION_STEPS[0]

    lower = user_text.lower().strip()
    question_like = ("?" in lower) or any(k in lower for k in ["how", "why", "what if", "i feel", "can i", "should i", "too hard"])

    if state.awaiting_confirmation and not _is_confirmation(user_text):
        current_step = _MEDITATION_STEPS[min(state.step_index, len(_MEDITATION_STEPS) - 1)]
        if question_like:
            return (
                "Good question. Keep it gentle: if this feels too intense, reduce the count and breathe naturally. "
                "No need to force anything. "
                f"Return to the current step: {current_step}"
            )
        return "Take your time. When you finish this step, say 'ready' and I’ll guide the next one."

    state.step_index += 1
    if state.step_index >= len(_MEDITATION_STEPS):
        _meditation_sessions.pop(user_id, None)
        return "Great work. You completed this round. Notice one small shift in your body, then drink some water. Want another short round?"

    state.awaiting_confirmation = True
    return _MEDITATION_STEPS[state.step_index]


def generate_reply(
    user_id: int,
    user_text: str,
    history: list[str],
    requested_mode: str | None = None,
    source: str | None = None,
) -> tuple[str, str, str, str]:
    emotion, _score, risk_level = analyze_text_emotion(user_text)
    mode = infer_mode(user_text, requested_mode, history)

    if mode != "meditation":
        _meditation_sessions.pop(user_id, None)

    if mode == "meditation":
        return _meditation_reply(user_id, user_text, risk_level), emotion, risk_level, mode

    if not settings.openai_api_key:
        return _fallback_reply(user_text, emotion, risk_level, mode), emotion, risk_level, mode

    try:
        from openai import OpenAI

        client = OpenAI(api_key=settings.openai_api_key)
        system_prompt = _build_system_prompt(mode, emotion, source=source)

        messages = [{"role": "system", "content": system_prompt}]
        for item in history[-8:]:
            role, content = item.split(":", 1)
            messages.append({"role": role, "content": content.strip()})
        messages.append({"role": "user", "content": user_text})

        model = settings.openai_voice_model if source == "voice" else settings.openai_model
        max_tokens = 110 if source == "voice" else 150

        resp = client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=0.45,
            max_tokens=max_tokens,
        )

        text = resp.choices[0].message.content or _fallback_reply(user_text, emotion, risk_level, mode)
        return text.strip(), emotion, risk_level, mode
    except Exception:
        return _fallback_reply(user_text, emotion, risk_level, mode), emotion, risk_level, mode
