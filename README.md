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
- `ios/NuraAI/NuraAIApp.swift`
- `ios/NuraAI/AppState.swift`
- `ios/NuraAI/RootView.swift`
- `ios/NuraAI/AuthView.swift`
- `ios/NuraAI/OnboardingView.swift`
- `ios/NuraAI/MainTabView.swift`
- `ios/NuraAI/TherapistView.swift`
- `ios/NuraAI/MeditationView.swift`
- `ios/NuraAI/DiscoverView.swift`
- `ios/NuraAI/ProfileView.swift`
- `ios/NuraAI/APIClient.swift`
- `ios/NuraAI/Models.swift`
- `ios/NuraAI/CalmBackground.swift`

### Xcode integration (no more manual add/remove every time)
1. Keep one Xcode project locally (for example: `NuraAI/NuraAI.xcodeproj`).
2. Add these Swift files to target once.
3. On each `git pull`, run:
   ```bash
   ./scripts/sync_ios_to_xcode.sh "$HOME/Documents/GitHub/nura-ai-assistant/NuraAI/NuraAI"
   ```
4. In Xcode: `Clean Build Folder` and Run.

This avoids repeated reference juggling.

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
