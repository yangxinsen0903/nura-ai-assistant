import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var messages: [LocalMessage] = []
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        HStack {
                            if msg.role == "assistant" {
                                Text("Nura")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(msg.content)
                                .padding(10)
                                .background(msg.role == "assistant" ? Color.gray.opacity(0.15) : Color.blue.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer()
                        }
                    }
                }
                .padding()
            }

            HStack {
                TextField("说点什么...", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(sending ? "..." : "发送") {
                    Task { await send() }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            .padding()
        }
    }

    @MainActor
    private func send() async {
        guard let userId = appState.userId else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        input = ""
        messages.append(LocalMessage(role: "user", content: text))
        sending = true
        defer { sending = false }

        do {
            let resp = try await APIClient.shared.sendMessage(baseURL: appState.apiBaseURL, userId: userId, content: text)
            messages.append(LocalMessage(role: "assistant", content: "[\(resp.emotion)] \(resp.reply)"))
        } catch {
            messages.append(LocalMessage(role: "assistant", content: "网络出错了，我们再试一次。"))
        }
    }
}
