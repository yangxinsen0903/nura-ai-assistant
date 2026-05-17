import SwiftUI
import AVFoundation
import Speech
import UIKit

struct TherapistView: View {
    @EnvironmentObject private var appState: AppState

    @State private var messages: [LocalMessage] = []
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
    @State private var bargeInMonitorTask: Task<Void, Never>?
    @State private var bargeInTriggered = false
    @State private var heardSpeechInTurn = false
    @State private var lastVoiceActivityAt = Date()
    @State private var recordingStartedAt = Date()
    @State private var lastStateTransitionAt = Date()
    @State private var sessionTurnId = 0
    @State private var speechStartedAt: Date?
    @State private var adaptivePauseSeconds: TimeInterval = 0.78

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
                if messages.isEmpty {
                    messages.append(LocalMessage(role: "assistant", content: greetingMessage()))
                }
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
                if rms > 0.008 {
                    DispatchQueue.main.async {
                        self.heardSpeechInTurn = true
                        if self.speechStartedAt == nil { self.speechStartedAt = Date() }
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
            speechStartedAt = nil
            lastVoiceActivityAt = Date()
            recordingStartedAt = Date()
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
                            if self.isConversationActive {
                                Task { await self.startRecording() }
                            }
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

        let speechDuration = max(0, Date().timeIntervalSince(speechStartedAt ?? recordingStartedAt))

        isRecording = false
        setVoiceState(.thinking)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil

        if text.isEmpty {
            if isConversationActive {
                setVoiceState(.listening)
                await startRecording()
            }
            return
        }

        if !isLikelyMeaningfulTranscript(text, speechDuration: speechDuration) {
            if isConversationActive {
                setVoiceState(.listening)
                await startRecording()
            }
            return
        }

        updateAdaptivePause(using: text, speechDuration: speechDuration)

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
        stopBargeInMonitor()

        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil

        audioPlayer?.stop()
        audioPlayer = nil
        synth.stopSpeaking(at: .immediate)

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
                    let recordingAge = Date().timeIntervalSince(self.recordingStartedAt)
                    let endSilence = self.dynamicTurnEndSilence(for: self.pendingTranscript)

                    if self.heardSpeechInTurn && silentFor > endSilence {
                        Task { await self.finalizeCurrentUtterance() }
                        return
                    }

                    // self-heal when recognizer stalls in listening too long
                    if recordingAge > 7.0 {
                        if !self.pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Task { await self.finalizeCurrentUtterance() }
                        } else {
                            self.isRecording = false
                            self.audioEngine.stop()
                            self.audioEngine.inputNode.removeTap(onBus: 0)
                            self.recognitionRequest?.endAudio()
                            self.recognitionTask?.cancel()
                            self.recognitionTask = nil
                            self.setVoiceState(.listening)
                            Task { await self.startRecording() }
                        }
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

    private func isLikelyMeaningfulTranscript(_ text: String, speechDuration: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        if speechDuration < 0.28 && trimmed.count < 4 {
            return false
        }

        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if letters + digits < 2 { return false }

        let tokens = trimmed.split { $0 == " " || $0 == "\n" || $0 == "\t" }
        if tokens.count == 1, trimmed.count <= 2 { return false }

        return true
    }

    private func updateAdaptivePause(using text: String, speechDuration: TimeInterval) {
        let words = max(1, text.split(separator: " ").count)
        let wps = Double(words) / max(0.3, speechDuration)

        let target: TimeInterval
        if wps >= 2.8 {
            target = 0.62
        } else if wps >= 2.0 {
            target = 0.75
        } else if wps >= 1.4 {
            target = 0.90
        } else {
            target = 1.05
        }

        adaptivePauseSeconds = max(0.55, min(1.15, 0.7 * adaptivePauseSeconds + 0.3 * target))
    }

    private func dynamicTurnEndSilence(for transcript: String) -> TimeInterval {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let connectorEndings = ["and", "because", "but", "so", "if", "when", "i", "um", "uh"]
        let trailingWord = lower.split(separator: " ").last.map(String.init) ?? ""

        var threshold = adaptivePauseSeconds
        if connectorEndings.contains(trailingWord) || lower.hasSuffix("...") {
            threshold += 0.22
        }
        if lower.count < 8 {
            threshold += 0.10
        }

        return max(0.55, min(1.30, threshold))
    }

    private func greetingMessage() -> String {
        let rawName = appState.profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstName = rawName.split(separator: " ").first.map(String.init) ?? ""
        if firstName.isEmpty {
            return "Hi, I’m Nura. How are you feeling right now?"
        }
        return "Hi \(firstName), I’m Nura. How are you feeling right now?"
    }

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if isConversationActive {
                // Prefer louder speaker output for hands-free assistant playback.
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay])
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
                try session.overrideOutputAudioPort(.speaker)
            }
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
        bargeInTriggered = false
        let speed = speechSpeed(emotion: emotion, riskLevel: riskLevel)
        do {
            let data = try await APIClient.shared.synthesizeSpeech(
                baseURL: appState.apiBaseURL,
                text: text,
                style: "warm_female",
                speed: speed
            )
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()

            if isConversationActive {
                startBargeInMonitor()
            }

            let started = audioPlayer?.play() ?? false
            guard started else {
                throw NSError(domain: "NuraVoice", code: -1001, userInfo: [NSLocalizedDescriptionKey: "TTS audio could not start playback"])
            }

            while audioPlayer?.isPlaying == true {
                if bargeInTriggered { break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            stopBargeInMonitor()

            if bargeInTriggered {
                return
            }
            if !isRecording { setVoiceState(.idle) }
        } catch {
            stopBargeInMonitor()
            await speakFallback(text, speed: speed)
        }
    }

    @MainActor
    private func speakFallback(_ text: String, speed: Double = 0.9) async {
        setVoiceState(.speaking)
        bargeInTriggered = false
        if isConversationActive {
            startBargeInMonitor()
        }

        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(max(0.38, min(0.50, speed * 0.50)))
        utterance.pitchMultiplier = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)

        let estimated = estimatedSpeechDuration(text: text, speed: speed)
        try? await Task.sleep(nanoseconds: UInt64(max(0.9, estimated) * 1_000_000_000))
        stopBargeInMonitor()

        if bargeInTriggered { return }
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
    private func startBargeInMonitor() {
        guard isConversationActive else { return }

        stopBargeInMonitor()
        bargeInTriggered = false

        do {
            try configureRecordSession()
        } catch {
            return
        }

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            if count <= 0 { return }
            var sum: Float = 0
            for i in 0..<count { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(count))
            if rms > 0.020 {
                DispatchQueue.main.async {
                    guard self.isConversationActive, self.voiceState == .speaking, !self.bargeInTriggered else { return }
                    self.bargeInTriggered = true
                    self.audioPlayer?.stop()
                    self.audioPlayer = nil
                    self.synth.stopSpeaking(at: .immediate)
                    self.stopBargeInMonitor()
                    self.setVoiceState(.listening)
                    Task { await self.startRecording() }
                }
            }
        }

        audioEngine.prepare()
        try? audioEngine.start()
    }

    @MainActor
    private func stopBargeInMonitor() {
        bargeInMonitorTask?.cancel()
        bargeInMonitorTask = nil
        if !isRecording {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
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
                        let recordingAge = Date().timeIntervalSince(self.recordingStartedAt)
                        if recordingAge > 9 {
                            self.isRecording = false
                            self.audioEngine.stop()
                            self.audioEngine.inputNode.removeTap(onBus: 0)
                            self.recognitionRequest?.endAudio()
                            self.recognitionTask?.cancel()
                            self.recognitionTask = nil
                            Task { await self.startRecording() }
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
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = state == .speaking ? 1.35 : (state == .listening ? 1.0 : 0.55)
            let pulse = 0.5 + 0.5 * sin(t * 7.2 * speed)
            let scale = state.scaleRange.lowerBound + (state.scaleRange.upperBound - state.scaleRange.lowerBound) * CGFloat(pulse)
            let palette = colors(for: state)

            ZStack {
                // Outer bloom halo
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

                // Fluid core (shader-like metaball feel using Canvas + additive blend)
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    context.addFilter(.blur(radius: 10))
                    context.blendMode = .plusLighter

                    for i in 0..<9 {
                        let fi = Double(i)
                        let angle = t * (0.9 + fi * 0.08) * speed + fi * 0.7
                        let radius = 26 + 18 * sin(t * 0.8 + fi)
                        let x = center.x + CGFloat(cos(angle) * radius)
                        let y = center.y + CGFloat(sin(angle * 1.2) * radius)
                        let blobSize = CGFloat(34 + 18 * (0.5 + 0.5 * sin(t * 1.7 + fi * 1.3)))

                        let rect = CGRect(x: x - blobSize / 2, y: y - blobSize / 2, width: blobSize, height: blobSize)
                        let c = fi.truncatingRemainder(dividingBy: 2) < 1 ? palette.primary.opacity(0.45) : palette.secondary.opacity(0.40)
                        context.fill(Path(ellipseIn: rect), with: .color(c))
                    }

                    // central body
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

                // Glass ring + moving specular highlight
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
