import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [DiscoverItem] = []

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground()

                List(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.type.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.white.opacity(0.75))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Discover")
            .task { await loadData() }
        }
    }

    @MainActor
    private func loadData() async {
        guard items.isEmpty else { return }
        items = (try? await APIClient.shared.fetchDiscover(baseURL: appState.apiBaseURL)) ?? []
    }
}
