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

Main files (single source of truth):
- `NuraAI/NuraAI/NuraAIApp.swift`
- `NuraAI/NuraAI/AppState.swift`
- `NuraAI/NuraAI/RootView.swift`
- `NuraAI/NuraAI/AuthView.swift`
- `NuraAI/NuraAI/OnboardingView.swift`
- `NuraAI/NuraAI/MainTabView.swift`
- `NuraAI/NuraAI/TherapistView.swift`
- `NuraAI/NuraAI/MeditationView.swift`
- `NuraAI/NuraAI/DiscoverView.swift`
- `NuraAI/NuraAI/ProfileView.swift`
- `NuraAI/NuraAI/APIClient.swift`
- `NuraAI/NuraAI/Models.swift`
- `NuraAI/NuraAI/CalmBackground.swift`
- `NuraAI/NuraAI/Info.plist`

### Xcode workflow (now simple)
1. Keep one Xcode project locally at `NuraAI/NuraAI.xcodeproj`.
2. Ensure target points to `NuraAI/NuraAI/*` files once.
3. After that, future updates are just:
   ```bash
   git pull origin master
   ```
4. In Xcode: `Clean Build Folder` and Run.

No sync script required anymore.

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
