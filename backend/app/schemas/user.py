from datetime import date
from pydantic import BaseModel


class OnboardingRequest(BaseModel):
    user_id: int
    name: str
    date_of_birth: date
    occupation: str
    has_therapist_treatment: bool


class ProfileResponse(BaseModel):
    user_id: int
    email: str
    name: str | None
    date_of_birth: date | None
    occupation: str | None
    has_therapist_treatment: bool | None
    onboarding_completed: bool
