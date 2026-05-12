import SwiftUI
import AVFoundation
import Speech
import UIKit

struct TherapistView: View {
    @EnvironmentObject private var appState: AppState

    @State private var messages: [LocalMessage] = [
        LocalMessage(role: "assistant", content: "Hi, I’m Nura. How are you feeling right now?")
    ]
    @State private var input = ""
    @State private var sending = false
    @State private var voiceReplyEnabled = true
    @State private var voiceOnlyMode = false
    @State private var isRecording = false
    @State private var activeMode: String = "chat"

    @State private var orbPulse = false
    @State private var voiceState: VoiceState = .idle
    @State private var alertMessage: String?

    private let synth = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?

    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                CalmBackground().onTapGesture { hideKeyboard() }

                VStack(spacing: 8) {
                    if voiceOnlyMode {
                        Spacer(minLength: 20)

                        Text(voiceState.title)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))

                        VoiceOrbView(state: voiceState, animate: orbPulse)
                            .frame(width: 220, height: 220)
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

                    HStack(spacing: 8) {
                        TextField("Share what’s on your mind...", text: $input, axis: .vertical)
                            .padding(10)
                            .background(.white.opacity(0.15))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .opacity(voiceOnlyMode ? 0.35 : 1)
                            .disabled(voiceOnlyMode)

                        Button(action: { Task { await sendText() } }) {
                            Text(sending ? "..." : "Send")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceOnlyMode)

                        Button {
                            Task { await toggleRecording() }
                        } label: {
                            Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(isRecording ? .red : .white)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Nura Therapist")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $voiceOnlyMode) {
                        Image(systemName: voiceOnlyMode ? "waveform" : "text.bubble")
                            .foregroundStyle(.white)
                    }
                    .labelsHidden()

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
            .onAppear {
                configurePlaybackSession()
                requestSpeechPermission()
                orbPulse = true
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

    @MainActor
    private func sendText() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        await sendUserMessage(text)
    }

    @MainActor
    private func sendUserMessage(_ text: String) async {
        guard let userId = appState.userId, !text.isEmpty else { return }

        if !voiceOnlyMode {
            messages.append(LocalMessage(role: "user", content: text))
        }
        sending = true
        voiceState = .thinking
        defer {
            sending = false
            if !isRecording { voiceState = .idle }
        }

        do {
            let resp = try await APIClient.shared.sendMessage(
                baseURL: appState.apiBaseURL,
                userId: userId,
                content: text,
                mode: activeMode
            )
            activeMode = resp.mode

            if !voiceOnlyMode {
                messages.append(LocalMessage(role: "assistant", content: resp.reply))
            }
            if voiceReplyEnabled {
                await speakNatural(resp.reply)
            }
        } catch {
            let fallback = "I’m here with you — connection had a hiccup. Let’s try again."
            if !voiceOnlyMode {
                messages.append(LocalMessage(role: "assistant", content: fallback))
            }
            if voiceReplyEnabled {
                await speakNatural(fallback)
            }
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    @MainActor
    private func toggleRecording() async {
        if isRecording {
            stopRecordingAndSend()
        } else {
            await startRecording()
        }
    }

    @MainActor
    private func startRecording() async {
        guard let recognizer, recognizer.isAvailable else {
            alertMessage = "Speech recognizer is currently unavailable."
            return
        }

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            alertMessage = "Please allow Speech Recognition in Settings."
            return
        }

        let micAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micAllowed else {
            alertMessage = "Please allow Microphone access in Settings."
            return
        }

        do {
            try configureRecordSession()
            audioPlayer?.stop()
            synth.stopSpeaking(at: .immediate)

            recognitionTask?.cancel()
            recognitionTask = nil

            let request = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest = request
            request.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            voiceOnlyMode = true
            voiceState = .listening

            var transcript = ""
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result = result {
                    transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        DispatchQueue.main.async {
                            self.isRecording = false
                            self.voiceState = .thinking
                            self.audioEngine.stop()
                            self.audioEngine.inputNode.removeTap(onBus: 0)
                            Task { await self.sendUserMessage(transcript) }
                        }
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.voiceState = .idle
                        self.audioEngine.stop()
                        self.audioEngine.inputNode.removeTap(onBus: 0)
                        self.alertMessage = "Voice input failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            isRecording = false
            voiceState = .idle
            alertMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func stopRecordingAndSend() {
        isRecording = false
        voiceState = .thinking
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .allowAirPlay])
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            // keep silent; fallback still works
        }
    }

    private func configureRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    @MainActor
    private func speakNatural(_ text: String) async {
        configurePlaybackSession()
        voiceState = .speaking
        do {
            let data = try await APIClient.shared.synthesizeSpeech(baseURL: appState.apiBaseURL, text: text, style: "warm_female")
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, (audioPlayer?.duration ?? 1.2))) {
                if !self.isRecording { self.voiceState = .idle }
            }
        } catch {
            speakFallback(text)
        }
    }

    private func speakFallback(_ text: String) {
        voiceState = .speaking
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.46
        utterance.pitchMultiplier = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.isRecording { self.voiceState = .idle }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private enum VoiceState {
    case idle
    case listening
    case thinking
    case speaking

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .white
        case .listening: return .cyan
        case .thinking: return .purple
        case .speaking: return .mint
        }
    }

    var scaleRange: ClosedRange<CGFloat> {
        switch self {
        case .idle: return 1.0...1.03
        case .listening: return 1.0...1.12
        case .thinking: return 0.96...1.02
        case .speaking: return 1.0...1.18
        }
    }
}

private struct VoiceOrbView: View {
    let state: VoiceState
    let animate: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color.opacity(0.20))
                .frame(width: 210, height: 210)
                .scaleEffect(animate ? state.scaleRange.upperBound : state.scaleRange.lowerBound)
                .blur(radius: 3)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [state.color.opacity(0.95), state.color.opacity(0.35)],
                        center: .center,
                        startRadius: 18,
                        endRadius: 110
                    )
                )
                .frame(width: 136, height: 136)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.5), lineWidth: 1)
                }
                .shadow(color: state.color.opacity(0.45), radius: 18, x: 0, y: 0)
                .scaleEffect(animate ? state.scaleRange.upperBound : state.scaleRange.lowerBound)
        }
        .animation(.easeInOut(duration: state == .speaking ? 0.28 : 0.7).repeatForever(autoreverses: true), value: animate)
    }
}
