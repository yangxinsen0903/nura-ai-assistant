import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if !appState.isLoggedIn {
                AuthView()
            } else if !appState.onboardingCompleted {
                OnboardingView()
            } else if appState.showWelcomeBackSplash {
                WelcomeBackView(firstName: appState.welcomeBackName)
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            appState.showWelcomeBackSplash = false
                        }
                    }
            } else {
                MainTabView()
            }
        }
    }
}

private struct WelcomeBackView: View {
    let firstName: String

    var body: some View {
        ZStack {
            CalmBackground()

            VStack(spacing: 14) {
                Text("Welcome back")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                Text(firstName)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
