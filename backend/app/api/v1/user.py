from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.models.user import User
from app.schemas.user import OnboardingRequest, ProfileResponse

router = APIRouter(prefix="/user", tags=["user"])


@router.post("/onboarding", response_model=ProfileResponse)
def complete_onboarding(payload: OnboardingRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == payload.user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    user.name = payload.name
    user.date_of_birth = payload.date_of_birth
    user.occupation = payload.occupation
    user.has_therapist_treatment = payload.has_therapist_treatment
    user.onboarding_completed = True
    db.commit()
    db.refresh(user)

    return ProfileResponse(
        user_id=user.id,
        email=user.email,
        name=user.name,
        date_of_birth=user.date_of_birth,
        occupation=user.occupation,
        has_therapist_treatment=user.has_therapist_treatment,
        onboarding_completed=user.onboarding_completed,
    )


@router.get("/profile/{user_id}", response_model=ProfileResponse)
def get_profile(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    return ProfileResponse(
        user_id=user.id,
        email=user.email,
        name=user.name,
        date_of_birth=user.date_of_birth,
        occupation=user.occupation,
        has_therapist_treatment=user.has_therapist_treatment,
        onboarding_completed=user.onboarding_completed,
    )
