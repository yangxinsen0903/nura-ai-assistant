import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground()

                VStack(spacing: 14) {
                    if let p = appState.profile {
                        profileRow("Email", p.email)
                        profileRow("Name", p.name ?? "-")
                        profileRow("Occupation", p.occupation ?? "-")
                        profileRow("Date of Birth", p.date_of_birth ?? "-")
                        profileRow("Therapist Treatment", (p.has_therapist_treatment ?? false) ? "Yes" : "No")
                    } else {
                        Text("Loading profile...")
                            .foregroundStyle(.white)
                    }

                    Button("Log Out") {
                        appState.logout()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Profile")
            .task {
                await loadProfile()
            }
        }
    }

    private func profileRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @MainActor
    private func loadProfile() async {
        guard appState.profile == nil, let userId = appState.userId else { return }
        appState.profile = try? await APIClient.shared.getProfile(baseURL: appState.apiBaseURL, userId: userId)
    }
}
