import SwiftUI

struct MeditationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [MeditationItem] = []

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground()

                List(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text("\(item.duration_min) min • \(item.category)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.white.opacity(0.75))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Meditation")
            .task { await loadData() }
        }
    }

    @MainActor
    private func loadData() async {
        guard items.isEmpty else { return }
        items = (try? await APIClient.shared.fetchMeditations(baseURL: appState.apiBaseURL)) ?? []
    }
}
