import SwiftUI

struct TherapistView: View {
    @EnvironmentObject private var appState: AppState

    @State private var messages: [LocalMessage] = [
        LocalMessage(role: "assistant", content: "Hi, I’m Nura. How are you feeling right now?")
    ]
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground()

                VStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { msg in
                                HStack {
                                    if msg.role == "assistant" { Spacer(minLength: 0) }
                                    Text(msg.content)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(msg.role == "assistant" ? Color.white.opacity(0.18) : Color.cyan.opacity(0.26))
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    if msg.role == "user" { Spacer(minLength: 0) }
                                }
                            }
                        }
                        .padding()
                    }

                    HStack(spacing: 8) {
                        TextField("Share what’s on your mind...", text: $input, axis: .vertical)
                            .padding(10)
                            .background(.white.opacity(0.15))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button(sending ? "..." : "Send") {
                            Task { await send() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding()
                }
            }
            .navigationTitle("Nura Therapist")
            .toolbarTitleDisplayMode(.inline)
        }
    }

    @MainActor
    private func send() async {
        guard let userId = appState.userId else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(LocalMessage(role: "user", content: text))
        input = ""
        sending = true
        defer { sending = false }

        do {
            let resp = try await APIClient.shared.sendMessage(baseURL: appState.apiBaseURL, userId: userId, content: text)
            messages.append(LocalMessage(role: "assistant", content: resp.reply))
        } catch {
            messages.append(LocalMessage(role: "assistant", content: "I’m here with you — connection had a hiccup. Let’s try again."))
        }
    }
}
