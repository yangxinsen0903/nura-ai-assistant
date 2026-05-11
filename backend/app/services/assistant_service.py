from __future__ import annotations

from app.core.config import settings
from app.services.emotion_service import analyze_text_emotion


def _fallback_reply(user_text: str, emotion: str, risk_level: str) -> str:
    if risk_level == "high":
        return (
            "我听到你现在非常难受。你不需要一个人扛着。"
            "如果你有伤害自己的冲动，请立刻联系当地紧急服务或危机热线，"
            "并告诉一位你信任的人你现在需要陪伴。"
        )
    if emotion == "anxious":
        return (
            "我在。先一起慢下来：吸气4秒，呼气6秒，做3轮。"
            "你愿意告诉我，眼下最压着你的那件事是什么吗？"
        )
    if emotion == "calm":
        return "听起来你在慢慢稳定下来，这是很好的信号。要不要我们顺着这个状态做一个今天的小目标？"
    return "我在听。你可以从现在最想说的一件事开始，我会陪你理清它。"


def generate_reply(user_text: str) -> tuple[str, str, str]:
    emotion, _score, risk_level = analyze_text_emotion(user_text)

    if not settings.openai_api_key:
        return _fallback_reply(user_text, emotion, risk_level), emotion, risk_level

    try:
        from openai import OpenAI

        client = OpenAI(api_key=settings.openai_api_key)
        system_prompt = (
            "You are Nura.ai, an empathetic emotional-support assistant. "
            "Do not provide medical diagnosis. Keep responses warm, concise, and safe. "
            "If severe self-harm intent appears, encourage immediate local emergency help."
        )
        resp = client.chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ],
            temperature=0.7,
        )
        text = resp.choices[0].message.content or _fallback_reply(user_text, emotion, risk_level)
        return text.strip(), emotion, risk_level
    except Exception:
        return _fallback_reply(user_text, emotion, risk_level), emotion, risk_level
