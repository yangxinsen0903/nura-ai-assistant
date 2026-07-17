import AVFoundation
import Combine
import Foundation

@MainActor
final class RealtimeSession: ObservableObject {

    enum RTState {
        case disconnected, connecting, listening, thinking, speaking
    }

    @Published var rtState: RTState = .disconnected

    var onUserTranscript: ((String) -> Void)?
    var onAssistantMessage: ((String) -> Void)?

    // Written on MainActor, read on audio tap thread — nonisolated(unsafe) is safe
    // because the tap is always removed before wsTask is set to nil.
    nonisolated(unsafe) private var wsTask: URLSessionWebSocketTask?
    // Gates mic during AI playback to prevent speaker echo re-entering the model
    nonisolated(unsafe) private var micMuted: Bool = false

    // Recreated each session to guarantee a clean engine graph
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()

    private let playFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var pendingReplyText = ""
    private var pendingBufferCount = 0
    private var responseDone = false

    // MARK: - Connect / Disconnect

    func connect(apiBaseURL: String, firstName: String) {
        guard rtState == .disconnected else { return }
        rtState = .connecting

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else { self.rtState = .disconnected; return }
                self.finishConnect(apiBaseURL: apiBaseURL, firstName: firstName)
            }
        }
    }

    private func finishConnect(apiBaseURL: String, firstName: String) {
        let wsBase = apiBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        let nameParam = firstName.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(wsBase)/realtime/ws?first_name=\(nameParam)"

        guard let url = URL(string: urlString) else {
            rtState = .disconnected; return
        }

        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        startReceiving()

        guard setupAudio() else {
            wsTask?.cancel(with: .goingAway, reason: nil)
            wsTask = nil
            rtState = .disconnected
            return
        }
        rtState = .listening
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        teardownAudio()
        pendingReplyText = ""
        pendingBufferCount = 0
        responseDone = false
        rtState = .disconnected
    }

    // MARK: - Audio Engine
    // Returns false if setup fails (engine can't start).

    @discardableResult
    private func setupAudio() -> Bool {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()

        let session = AVAudioSession.sharedInstance()
        do {
            // No setPreferredSampleRate — let hardware choose; we resample in callback
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            print("[RT] AVAudioSession error: \(error)")
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFmt)

        // nil format: engine uses native hardware format for the tap.
        // buffer.format in the callback has the real sample rate — no upfront query needed.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.handleMicBuffer(buf)
        }

        do {
            try engine.start()
        } catch {
            print("[RT] engine.start() failed: \(error)")
            engine.inputNode.removeTap(onBus: 0)
            return false
        }

        player.play()
        return true
    }

    private func teardownAudio() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
    }

    // MARK: - Mic → WebSocket (audio tap thread)

    private nonisolated func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let src = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += src[i] * src[i] }
        return (sum / Float(n)).squareRoot()
    }

    private nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let ws = wsTask else { return }

        if micMuted {
            // AEC (voiceChat mode) suppresses speaker echo; energy > 0.06 = real user speech → barge-in
            if rms(buffer) > 0.06 {
                Task { @MainActor [weak self] in self?.triggerBargeIn() }
            }
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let src = buffer.floatChannelData?[0] else { return }

        let srcRate = buffer.format.sampleRate
        guard srcRate > 0 else { return }

        // Linear-interpolation resample to 24 kHz, then Float32 → Int16
        let step   = srcRate / 24_000.0
        let outLen = max(1, Int(Double(frameCount) / step))
        var pcm16  = [Int16](repeating: 0, count: outLen)

        for i in 0..<outLen {
            let pos  = Double(i) * step
            let lo   = Int(pos)
            let hi   = min(lo + 1, frameCount - 1)
            let frac = Float(pos - Double(lo))
            let s    = src[lo] + frac * (src[hi] - src[lo])
            pcm16[i] = Int16(max(-32_767, min(32_767, Int32(s * 32_767))))
        }

        let raw   = Data(bytes: pcm16, count: pcm16.count * 2)
        let event = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(raw.base64EncodedString())\"}"
        ws.send(.string(event)) { _ in }
    }

    // MARK: - WebSocket receive loop

    private func startReceiving() {
        wsTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    let text: String
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default:    text = ""
                    }
                    if !text.isEmpty { self.handleEvent(text) }
                    self.startReceiving()
                case .failure(let err):
                    print("[RT] ws receive error: \(err)")
                    if self.rtState != .disconnected { self.rtState = .disconnected }
                }
            }
        }
    }

    // MARK: - Event handler

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "input_audio_buffer.speech_started":
            // This fires if barge-in happens before mic was muted — just reset state
            player.stop()
            player.play()
            micMuted = false
            pendingReplyText = ""
            pendingBufferCount = 0
            responseDone = false
            rtState = .listening

        case "input_audio_buffer.speech_stopped":
            rtState = .thinking

        case "response.created", "response.output_item.added":
            rtState = .thinking

        // GA API (June 2026): event names changed from beta
        case "response.output_audio.delta":
            guard let delta = json["delta"] as? String,
                  let raw = Data(base64Encoded: delta),
                  raw.count >= 2 else { return }
            micMuted = true   // mute mic while AI is speaking to prevent echo loop
            rtState = .speaking
            scheduleAudioChunk(raw)

        case "response.output_audio.done":
            responseDone = true
            checkTransitionToListening()
            let msg = pendingReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { onAssistantMessage?(msg) }
            pendingReplyText = ""

        case "response.output_audio_transcript.delta":
            if let d = json["delta"] as? String { pendingReplyText += d }

        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.delta":
            if let t = (json["transcript"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                onUserTranscript?(t)
            }

        case "error":
            print("[RT] OpenAI error: \(text)")

        default:
            break
        }
    }

    // MARK: - Playback

    private func triggerBargeIn() {
        guard rtState == .speaking || rtState == .thinking else { return }
        player.stop()
        player.play()
        micMuted = false
        pendingReplyText = ""
        pendingBufferCount = 0
        responseDone = false
        wsTask?.send(.string("{\"type\":\"input_audio_buffer.clear\"}")) { _ in }
        rtState = .listening
    }

    private func scheduleAudioChunk(_ raw: Data) {
        let frameCount = raw.count / 2
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playFmt,
                                         frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)

        raw.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress,
                  let dst = buf.floatChannelData?[0] else { return }
            // 3.5× gain to match previous TTS volume; clamp to avoid clipping
            for i in 0..<frameCount {
                dst[i] = max(-1.0, min(1.0, Float(src[i]) / 32_767.0 * 3.5))
            }
        }

        pendingBufferCount += 1
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
                self.checkTransitionToListening()
            }
        }
    }

    private func checkTransitionToListening() {
        if responseDone && pendingBufferCount == 0 && rtState == .speaking {
            wsTask?.send(.string("{\"type\":\"input_audio_buffer.clear\"}")) { _ in }
            micMuted = false
            rtState = .listening
            responseDone = false
        }
    }
}
