from fastapi import APIRouter

router = APIRouter(prefix="/content", tags=["content"])


@router.get("/meditations")
def meditations():
    return [
        {"id": "m1", "title": "Deep Sleep Reset", "duration_min": 15, "category": "Sleep"},
        {"id": "m2", "title": "Calm Anxiety in 10", "duration_min": 10, "category": "Anxiety"},
        {"id": "m3", "title": "Morning Clarity", "duration_min": 12, "category": "Focus"},
    ]


@router.get("/discover")
def discover():
    return [
        {"id": "d1", "title": "How to quiet racing thoughts", "type": "article"},
        {"id": "d2", "title": "3-minute grounding drill", "type": "audio"},
        {"id": "d3", "title": "Build a softer inner voice", "type": "guide"},
    ]
