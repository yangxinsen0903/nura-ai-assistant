import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if !appState.isLoggedIn {
                AuthView()
            } else if !appState.onboardingCompleted {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
    }
}
