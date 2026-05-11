from __future__ import annotations

NEGATIVE = {"焦虑", "难受", "绝望", "崩溃", "压力", "害怕", "失眠", "痛苦"}
POSITIVE = {"开心", "放松", "高兴", "平静", "满足", "有希望"}
RISK = {"不想活", "自杀", "结束生命", "伤害自己", "活不下去"}


def analyze_text_emotion(text: str) -> tuple[str, float, str]:
    t = text.strip()
    if any(k in t for k in RISK):
        return "high_distress", 0.95, "high"

    neg_hits = sum(1 for k in NEGATIVE if k in t)
    pos_hits = sum(1 for k in POSITIVE if k in t)

    if neg_hits > pos_hits:
        score = min(0.9, 0.45 + 0.15 * neg_hits)
        return "anxious", score, "medium"
    if pos_hits > neg_hits:
        score = min(0.9, 0.45 + 0.15 * pos_hits)
        return "calm", score, "low"

    return "neutral", 0.5, "low"
