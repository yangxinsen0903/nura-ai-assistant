import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            TherapistView()
                .tag(AppState.Tab.therapist)
                .tabItem { Label("Therapist", systemImage: "message.fill") }

            MeditationView()
                .tag(AppState.Tab.meditation)
                .tabItem { Label("Meditation", systemImage: "waveform") }

            DiscoverView()
                .tag(AppState.Tab.discover)
                .tabItem { Label("Discover", systemImage: "sparkles") }

            ProfileView()
                .tag(AppState.Tab.profile)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .tint(.cyan)
    }
}
