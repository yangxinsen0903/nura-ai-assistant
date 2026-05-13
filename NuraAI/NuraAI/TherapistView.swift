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

    @State private var voiceState: VoiceState = .idle
    @State private var alertMessage: String?
    @State private var isConversationActive = false
    @State private var pendingTranscript = ""
    @State private var idleSessionTask: Task<Void, Never>?
    @State private var silenceWatcherTask: Task<Void, Never>?
    @State private var sessionWatchdogTask: Task<Void, Never>?
    @State private var heardSpeechInTurn = false
    @State private var lastVoiceActivityAt = Date()
    @State private var lastStateTransitionAt = Date()
    @State private var sessionTurnId = 0

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
                        HStack {
                            Spacer()
                            Button {
                                Task { await stopConversationSession(byVoiceCommand: false) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                            .padding(.trailing, 14)
                            .padding(.top, 8)
                        }

                        Spacer(minLength: 10)

                        Text(voiceState.title)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))

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
                            TextField("Share what’s on your mind...", text: $input, axis: .vertical)
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

                            Button {
                                Task { await toggleRecording() }
                            } label: {
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
                configurePlaybackSession()
                requestSpeechPermission()
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
    private func sendUserMessage(_ text: String, fromHandsFree: Bool = false) async {
        guard let userId = appState.userId, !text.isEmpty else { return }

        if fromHandsFree && text.count < 2 {
            if isConversationActive { await startRecording() }
            return
        }

        if !voiceOnlyMode {
            messages.append(LocalMessage(role: "user", content: text))
        }
        sessionTurnId += 1
        let turnId = sessionTurnId

        sending = true
        setVoiceState(.thinking)
        var shouldResumeHandsFree = false

        do {
            let resp = try await APIClient.shared.sendMessage(
                baseURL: appState.apiBaseURL,
                userId: userId,
                content: text,
                mode: activeMode,
                source: fromHandsFree ? "voice" : "text"
            )
            if turnId != sessionTurnId { return }
            activeMode = resp.mode

            if !voiceOnlyMode {
                messages.append(LocalMessage(role: "assistant", content: resp.reply))
            }
            if voiceReplyEnabled {
                await speakNatural(resp.reply, emotion: resp.emotion, riskLevel: resp.risk_level)
            }
        } catch {
            let detail = error.localizedDescription
            let lowered = detail.lowercased()
            let ns = error as NSError
            if error is CancellationError || lowered.contains("cancel") || ns.code == NSURLErrorCancelled {
                sending = false
                if fromHandsFree && isConversationActive {
                    setVoiceState(.listening)
                    await startRecording()
                } else if !isRecording {
                    setVoiceState(.idle)
                }
                return
            }

            let fallback = "I’m having trouble reaching the server right now. Please try again."
            if !voiceOnlyMode {
                messages.append(LocalMessage(role: "assistant", content: "\(fallback) (\(detail))"))
            }
            alertMessage = "Send failed: \(detail)"
            if voiceReplyEnabled {
                await speakNatural(fallback)
            }
        }

        scheduleIdleSessionTimeout()
        if fromHandsFree && isConversationActive {
            shouldResumeHandsFree = true
        }

        sending = false
        if shouldResumeHandsFree && isConversationActive {
            setVoiceState(.listening)
            await startRecording()
        } else if !isRecording {
            setVoiceState(.idle)
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    @MainActor
    private func toggleRecording() async {
        if isConversationActive {
            await stopConversationSession(byVoiceCommand: false)
        } else {
            isConversationActive = true
            voiceOnlyMode = true
            voiceReplyEnabled = true // hands-free session always speaks back
            sessionTurnId = 0
            scheduleIdleSessionTimeout()
            startSessionWatchdog()
            await startRecording()
        }
    }

    @MainActor
    private func startRecording() async {
        if isRecording || sending { return }

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
            request.taskHint = .dictation

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)

                // basic energy-based VAD for hands-free turn end
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                if count <= 0 { return }
                var sum: Float = 0
                for i in 0..<count { sum += channel[i] * channel[i] }
                let rms = sqrt(sum / Float(count))
                if rms > 0.012 {
                    DispatchQueue.main.async {
                        self.heardSpeechInTurn = true
                        self.lastVoiceActivityAt = Date()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            voiceOnlyMode = true
            setVoiceState(.listening)
            heardSpeechInTurn = false
            lastVoiceActivityAt = Date()
            startSilenceWatcher()

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        let transcript = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.pendingTranscript = transcript
                        self.scheduleIdleSessionTimeout()
                        if result.isFinal {
                            Task { await self.finalizeCurrentUtterance() }
                        }
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        let msg = error.localizedDescription.lowercased()
                        self.isRecording = false
                        self.audioEngine.stop()
                        self.audioEngine.inputNode.removeTap(onBus: 0)

                        if msg.contains("cancel") {
                            return
                        }

                        if msg.contains("no speech") || msg.contains("no speech detected") {
                            self.setVoiceState(.listening)
                            if self.isConversationActive {
                                Task { await self.startRecording() }
                            } else {
                                self.setVoiceState(.idle)
                            }
                            return
                        }

                        self.setVoiceState(.idle)
                        self.alertMessage = "Voice input failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            isRecording = false
            setVoiceState(.idle)
            alertMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func finalizeCurrentUtterance() async {
        guard isRecording || !(pendingTranscript.isEmpty) else { return }

        silenceWatcherTask?.cancel()
        silenceWatcherTask = nil

        let text = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTranscript = ""

        isRecording = false
        setVoiceState(.thinking)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil

        if text.isEmpty {
            if isConversationActive {
                if heardSpeechInTurn {
                    alertMessage = "I heard audio but couldn't transcribe it. Please speak a bit slower and closer to the mic."
                }
                setVoiceState(.listening)
                await startRecording()
            }
            return
        }

        if shouldEndConversation(text) {
            await stopConversationSession(byVoiceCommand: true)
            return
        }

        await sendUserMessage(text, fromHandsFree: true)
    }

    @MainActor
    private func stopConversationSession(byVoiceCommand: Bool) async {
        isConversationActive = false
        isRecording = false
        pendingTranscript = ""
        idleSessionTask?.cancel()
        idleSessionTask = nil
        silenceWatcherTask?.cancel()
        silenceWatcherTask = nil
        sessionWatchdogTask?.cancel()
        sessionWatchdogTask = nil

        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil

        setVoiceState(.idle)
        voiceOnlyMode = false

        if byVoiceCommand {
            messages.append(LocalMessage(role: "assistant", content: "Session ended. I’m here whenever you want to continue."))
        }
    }

    @MainActor
    private func startSilenceWatcher() {
        silenceWatcherTask?.cancel()
        silenceWatcherTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.isConversationActive, self.isRecording, !self.sending else { return }
                    let silentFor = Date().timeIntervalSince(self.lastVoiceActivityAt)
                    if self.heardSpeechInTurn && silentFor > 1.05 {
                        Task { await self.finalizeCurrentUtterance() }
                    }
                }
            }
        }
    }

    @MainActor
    private func scheduleIdleSessionTimeout() {
        idleSessionTask?.cancel()
        idleSessionTask = Task {
            try? await Task.sleep(nanoseconds: 240_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if self.isConversationActive && !self.isRecording && !self.sending {
                    Task { await self.stopConversationSession(byVoiceCommand: false) }
                }
            }
        }
    }

    private func shouldEndConversation(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("end conversation") || t.contains("stop session") || t.contains("结束对话") || t.contains("结束会话")
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
    private func speakNatural(_ text: String, emotion: String = "neutral", riskLevel: String = "low") async {
        configurePlaybackSession()
        setVoiceState(.speaking)
        let speed = speechSpeed(emotion: emotion, riskLevel: riskLevel)
        do {
            let data = try await APIClient.shared.synthesizeSpeech(
                baseURL: appState.apiBaseURL,
                text: text,
                style: "warm_female",
                speed: speed
            )
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()

            let started = audioPlayer?.play() ?? false
            guard started else {
                throw NSError(domain: "NuraVoice", code: -1001, userInfo: [NSLocalizedDescriptionKey: "TTS audio could not start playback"])
            }

            while audioPlayer?.isPlaying == true {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if !isRecording { setVoiceState(.idle) }
        } catch {
            await speakFallback(text, speed: speed)
        }
    }

    @MainActor
    private func speakFallback(_ text: String, speed: Double = 0.9) async {
        setVoiceState(.speaking)
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(max(0.38, min(0.50, speed * 0.50)))
        utterance.pitchMultiplier = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)

        let estimated = estimatedSpeechDuration(text: text, speed: speed)
        try? await Task.sleep(nanoseconds: UInt64(max(0.9, estimated) * 1_000_000_000))
        if !isRecording { setVoiceState(.idle) }
    }

    private func speechSpeed(emotion: String, riskLevel: String) -> Double {
        if riskLevel == "high" { return 0.80 }
        if emotion == "anxious" || emotion == "high_distress" { return 0.84 }
        if emotion == "calm" { return 0.92 }
        return 0.90
    }

    private func estimatedSpeechDuration(text: String, speed: Double) -> Double {
        let words = max(1, text.split(separator: " ").count)
        let baseWps = 2.4 * max(0.7, speed)
        return Double(words) / baseWps + 0.4
    }

    @MainActor
    private func setVoiceState(_ state: VoiceState) {
        voiceState = state
        lastStateTransitionAt = Date()
    }

    @MainActor
    private func startSessionWatchdog() {
        sessionWatchdogTask?.cancel()
        sessionWatchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.isConversationActive else { return }

                    let stalledFor = Date().timeIntervalSince(self.lastStateTransitionAt)
                    if self.voiceState == .listening && !self.isRecording {
                        Task { await self.startRecording() }
                        return
                    }

                    if self.voiceState == .listening && self.isRecording {
                        let quietFor = Date().timeIntervalSince(self.lastVoiceActivityAt)
                        if quietFor > 10 {
                            self.pendingTranscript = ""
                            self.heardSpeechInTurn = false
                        }
                    }

                    if self.voiceState == .thinking && self.sending && stalledFor > 15 {
                        self.sending = false
                        self.setVoiceState(.listening)
                        Task { await self.startRecording() }
                    }
                }
            }
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * (state == .speaking ? 8.5 : state == .listening ? 5.5 : 2.2))
            let slow = 0.5 + 0.5 * sin(t * 1.1)
            let baseScale = state.scaleRange.lowerBound + (state.scaleRange.upperBound - state.scaleRange.lowerBound) * CGFloat(pulse)

            ZStack {
                // soft outer aura
                Circle()
                    .fill(state.color.opacity(0.10 + 0.18 * slow))
                    .frame(width: 220, height: 220)
                    .scaleEffect(1.0 + 0.08 * CGFloat(slow))
                    .blur(radius: 8)

                // animated rings
                ForEach(0..<3, id: \.self) { idx in
                    let offset = Double(idx) * 0.9
                    let ringPulse = 0.5 + 0.5 * sin((t + offset) * (state == .speaking ? 6.0 : 3.0))
                    Circle()
                        .stroke(state.color.opacity(0.12 + 0.22 * ringPulse), lineWidth: 2)
                        .frame(width: 150 + CGFloat(idx) * 28, height: 150 + CGFloat(idx) * 28)
                        .scaleEffect(0.95 + 0.09 * CGFloat(ringPulse))
                        .blur(radius: idx == 2 ? 2 : 0)
                }

                // floating blobs around core
                ForEach(0..<6, id: \.self) { i in
                    let fi = Double(i)
                    let angle = t * (state == .speaking ? 1.9 : 1.1) + fi * (.pi * 2 / 6)
                    let radius: CGFloat = state == .speaking ? 54 : 48
                    Circle()
                        .fill(state.color.opacity(0.20))
                        .frame(width: state == .speaking ? 18 : 14, height: state == .speaking ? 18 : 14)
                        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                        .blur(radius: 1)
                }

                // core orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [state.color.opacity(0.98), state.color.opacity(0.48), .white.opacity(0.12)],
                            center: .center,
                            startRadius: 6,
                            endRadius: 90
                        )
                    )
                    .frame(width: 134, height: 134)
                    .overlay {
                        Circle().stroke(.white.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: state.color.opacity(0.55), radius: 24, x: 0, y: 0)
                    .scaleEffect(baseScale)
            }
        }
    }
}
