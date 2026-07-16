import AVFoundation
import SwiftUI
import UIKit

struct TherapistView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var rt = RealtimeSession()

    @State private var messages: [LocalMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var voiceOnlyMode = false
    @State private var activeMode: String = "chat"
    @State private var alertMessage: String?

    private var isConversationActive: Bool { rt.rtState != .disconnected }

    private var voiceState: VoiceState {
        switch rt.rtState {
        case .disconnected, .connecting: return .idle
        case .listening:                 return .listening
        case .thinking:                  return .thinking
        case .speaking:                  return .speaking
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground().onTapGesture { hideKeyboard() }

                VStack(spacing: 8) {
                    if voiceOnlyMode {
                        HStack {
                            Spacer()
                            Button {
                                rt.disconnect()
                                voiceOnlyMode = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                            .padding(.trailing, 14)
                            .padding(.top, 8)
                        }

                        Spacer(minLength: 18)

                        VoiceOrbView(state: voiceState)
                            .frame(width: 230, height: 230)
                            .padding(.top, 8)

                        Spacer()
                    } else {
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
                    }

                    if !voiceOnlyMode {
                        HStack(spacing: 8) {
                            TextField("Share what's on your mind...", text: $input, axis: .vertical)
                                .padding(10)
                                .background(.white.opacity(0.15))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button(action: { Task { await sendText() } }) {
                                Text(sending ? "..." : "Send")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                            .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button { toggleConversation() } label: {
                                Image(systemName: "waveform.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Nura Therapist")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
            }
            .onAppear {
                if messages.isEmpty {
                    messages.append(LocalMessage(role: "assistant", content: greetingMessage()))
                }
                rt.onUserTranscript = { transcript in
                    messages.append(LocalMessage(role: "user", content: transcript))
                }
                rt.onAssistantMessage = { reply in
                    messages.append(LocalMessage(role: "assistant", content: reply))
                }
            }
            .onChange(of: rt.rtState) { _, newState in
                if newState == .disconnected { voiceOnlyMode = false }
            }
            .alert("Voice Error", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "Unknown error")
            }
        }
    }

    // MARK: - Actions

    private func toggleConversation() {
        if isConversationActive {
            rt.disconnect()
            voiceOnlyMode = false
        } else {
            voiceOnlyMode = true
            let rawName = appState.profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let firstName = rawName.split(separator: " ").first.map(String.init) ?? ""
            rt.connect(apiBaseURL: appState.apiBaseURL, firstName: firstName)
        }
    }

    @MainActor
    private func sendText() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(LocalMessage(role: "user", content: text))
        sending = true
        defer { sending = false }

        guard let userId = appState.userId else { return }
        do {
            let resp = try await APIClient.shared.sendMessage(
                baseURL: appState.apiBaseURL,
                userId: userId,
                content: text,
                mode: activeMode,
                source: "text"
            )
            activeMode = resp.mode
            messages.append(LocalMessage(role: "assistant", content: resp.reply))
        } catch {
            let msg = "I'm having trouble reaching the server. (\(error.localizedDescription))"
            messages.append(LocalMessage(role: "assistant", content: msg))
        }
    }

    private func greetingMessage() -> String {
        let rawName = appState.profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstName = rawName.split(separator: " ").first.map(String.init) ?? ""
        if firstName.isEmpty {
            return "Hi, I'm Nura. How are you feeling right now?"
        }
        return "Hi \(firstName), I'm Nura. How are you feeling right now?"
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - VoiceState

private enum VoiceState {
    case idle, listening, thinking, speaking

    var title: String {
        switch self {
        case .idle:      return "Ready"
        case .listening: return "Listening"
        case .thinking:  return "Thinking"
        case .speaking:  return "Speaking"
        }
    }

    var color: Color {
        switch self {
        case .idle:      return .white
        case .listening: return .cyan
        case .thinking:  return .purple
        case .speaking:  return .mint
        }
    }

    var scaleRange: ClosedRange<CGFloat> {
        switch self {
        case .idle:      return 1.0...1.03
        case .listening: return 1.0...1.12
        case .thinking:  return 0.96...1.02
        case .speaking:  return 1.0...1.18
        }
    }
}

// MARK: - VoiceOrbView

private struct VoiceOrbView: View {
    let state: VoiceState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = state == .speaking ? 1.35 : (state == .listening ? 1.0 : 0.55)
            let pulse = 0.5 + 0.5 * sin(t * 7.2 * speed)
            let scale = state.scaleRange.lowerBound + (state.scaleRange.upperBound - state.scaleRange.lowerBound) * CGFloat(pulse)
            let palette = colors(for: state)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [palette.outer.opacity(0.45), .clear],
                            center: .center,
                            startRadius: 8,
                            endRadius: 135
                        )
                    )
                    .frame(width: 250, height: 250)
                    .blur(radius: 20)
                    .scaleEffect(1.0 + 0.08 * CGFloat(pulse))

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    context.addFilter(.blur(radius: 10))
                    context.blendMode = .plusLighter

                    for i in 0..<9 {
                        let fi = Double(i)
                        let angle = t * (0.9 + fi * 0.08) * speed + fi * 0.7
                        let radius = 26.0 + 18.0 * sin(t * 0.8 + fi)
                        let x = center.x + CGFloat(cos(angle) * radius)
                        let y = center.y + CGFloat(sin(angle * 1.2) * radius)
                        let wobble = sin(t * 1.7 + fi * 1.3)
                        let blobSizeDouble = 34.0 + 18.0 * (0.5 + 0.5 * wobble)
                        let blobSize = CGFloat(blobSizeDouble)
                        let rect = CGRect(x: x - blobSize / 2, y: y - blobSize / 2, width: blobSize, height: blobSize)
                        let usePrimary = fi.truncatingRemainder(dividingBy: 2) < 1
                        let c: Color = usePrimary ? palette.primary.opacity(0.45) : palette.secondary.opacity(0.40)
                        context.fill(Path(ellipseIn: rect), with: .color(c))
                    }

                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 56, y: center.y - 56, width: 112, height: 112)),
                        with: .radialGradient(
                            Gradient(colors: [palette.highlight, palette.primary.opacity(0.9), palette.secondary.opacity(0.75), .clear]),
                            center: center,
                            startRadius: 2,
                            endRadius: 70
                        )
                    )
                }
                .frame(width: 180, height: 180)
                .scaleEffect(scale)

                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [palette.highlight.opacity(0.95), palette.primary.opacity(0.55), palette.secondary.opacity(0.75), palette.highlight.opacity(0.3)],
                            center: .center,
                            angle: .degrees(t * 30 * speed)
                        ),
                        lineWidth: 2.2
                    )
                    .frame(width: 154, height: 154)
                    .blur(radius: 0.4)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [palette.highlight.opacity(0.85), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 122, height: 122)
                    .offset(x: -18 + 4 * CGFloat(sin(t * 1.2)), y: -22 + 4 * CGFloat(cos(t * 1.1)))
                    .blendMode(.screen)
                    .blur(radius: 1.3)

                Circle()
                    .stroke(palette.outer.opacity(0.24), lineWidth: 1.0)
                    .frame(width: 186, height: 186)
                    .scaleEffect(0.96 + 0.06 * CGFloat(0.5 + 0.5 * sin(t * 2.0 * speed)))
            }
            .compositingGroup()
        }
    }

    private func colors(for state: VoiceState) -> (primary: Color, secondary: Color, highlight: Color, outer: Color) {
        switch state {
        case .idle:
            return (.cyan.opacity(0.85), .blue.opacity(0.75), .white, .cyan)
        case .listening:
            return (.mint.opacity(0.92), .cyan.opacity(0.82), .white, .mint)
        case .thinking:
            return (.purple.opacity(0.9), .indigo.opacity(0.78), .white.opacity(0.95), .purple)
        case .speaking:
            return (.blue.opacity(0.9), .mint.opacity(0.82), .white, .cyan)
        }
    }
}
