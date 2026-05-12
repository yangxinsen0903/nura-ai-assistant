import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            TherapistView()
                .tabItem { Label("Therapist", systemImage: "message.fill") }

            MeditationView()
                .tabItem { Label("Meditation", systemImage: "waveform") }

            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .tint(.cyan)
    }
}
