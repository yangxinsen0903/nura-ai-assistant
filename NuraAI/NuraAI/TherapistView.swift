import SwiftUI
import AVFoundation
import UIKit

struct TherapistView: View {
    @EnvironmentObject private var appState: AppState

    @State private var messages: [LocalMessage] = [
        LocalMessage(role: "assistant", content: "Hi, I’m Nura. How are you feeling right now?")
    ]
    @State private var input = ""
    @State private var sending = false
    @State private var voiceReplyEnabled = true

    private let synth = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground()
                    .onTapGesture { hideKeyboard() }

                VStack(spacing: 8) {
                    // quick tab switch pills so user can always escape chat
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quickTabPill("Therapy", .therapist)
                            quickTabPill("Meditation", .meditation)
                            quickTabPill("Discover", .discover)
                            quickTabPill("Profile", .profile)
                        }
                        .padding(.horizontal)
                    }

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $voiceReplyEnabled) {
                        Image(systemName: voiceReplyEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(.white)
                    }
                    .labelsHidden()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
            }
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
            if voiceReplyEnabled {
                speak(resp.reply)
            }
        } catch {
            let fallback = "I’m here with you — connection had a hiccup. Let’s try again."
            messages.append(LocalMessage(role: "assistant", content: fallback))
            if voiceReplyEnabled {
                speak(fallback)
            }
        }
    }

    @ViewBuilder
    private func quickTabPill(_ title: String, _ tab: AppState.Tab) -> some View {
        Button {
            appState.selectedTab = tab
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(appState.selectedTab == tab ? Color.cyan.opacity(0.35) : Color.white.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.white)
        }
    }

    private func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.95
        utterance.voice = preferredFemaleVoice() ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }

    private func preferredFemaleVoice() -> AVSpeechSynthesisVoice? {
        let prefs = ["Samantha", "Ava", "Allison", "Karen", "Moira"]
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        for name in prefs {
            if let v = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return v
            }
        }
        return voices.first
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
