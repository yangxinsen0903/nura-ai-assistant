# Nura.ai (MVP v0.2)

Independent product (unrelated to NuraLogix).

## Current scope
- English-only UI
- Email/password auth
- First-time onboarding (name, DOB, occupation, therapist treatment yes/no)
- Home as 4 tabs:
  - Therapist
  - Meditation
  - Discover
  - Profile
- Calm-inspired visual style (soft gradient + glass cards)

---

## Backend
Path: `backend/`

### Run locally
```bash
cd backend
./run_local.sh
```

### APIs
- `POST /api/v1/auth/register`
- `POST /api/v1/auth/login`
- `POST /api/v1/user/onboarding`
- `GET /api/v1/user/profile/{user_id}`
- `POST /api/v1/chat/message`
- `POST /api/v1/emotion/analyze`
- `GET /api/v1/content/meditations`
- `GET /api/v1/content/discover`
- `GET /healthz`

---

## iOS source files
Path: `ios/NuraAI/`

Main files:
- `NuraAIApp.swift`
- `AppState.swift`
- `RootView.swift`
- `AuthView.swift`
- `OnboardingView.swift`
- `MainTabView.swift`
- `TherapistView.swift`
- `MeditationView.swift`
- `DiscoverView.swift`
- `ProfileView.swift`
- `APIClient.swift`
- `Models.swift`
- `CalmBackground.swift`

### Xcode integration
1. Create iOS SwiftUI project named `NuraAI`.
2. Copy above files into your target.
3. Ensure `apiBaseURL` points to VPS endpoint:
   - `http://100.99.145.120:8010/api/v1`
4. Add ATS exception for HTTP during MVP testing.

---

## VPS
Systemd service name:
- `nura-ai-backend.service`

Useful commands:
```bash
systemctl --user status nura-ai-backend.service
systemctl --user restart nura-ai-backend.service
journalctl --user -u nura-ai-backend.service -f
```
