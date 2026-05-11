import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                ChatView()
            } else {
                OnboardingView()
            }
        }
    }
}
