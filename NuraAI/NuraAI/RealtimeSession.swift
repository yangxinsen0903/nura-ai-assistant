import AVFoundation
import Foundation

// MARK: - RealtimeSession
// Manages a WebSocket connection to the backend /api/v1/realtime/ws endpoint,
// which proxies to the OpenAI Realtime API. Handles bidirectional PCM16 audio
// streaming for sub-second latency voice conversation.

@MainActor
final class RealtimeSession: NSObject, ObservableObject {

    enum RTState {
        case disconnected, connecting, listening, thinking, speaking
    }

    @Published var rtState: RTState = .disconnected

    // Fired on main thread when the user's speech is transcribed
    var onUserTranscript: ((String) -> Void)?
    // Fired on main thread when a complete assistant reply text is available
    var onAssistantMessage: ((String) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var inputConverter: AVAudioConverter?

    // Accumulate assistant transcript deltas until response.audio.done
    private var pendingReplyText = ""
    // Track scheduled-but-not-yet-played buffers for accurate speaking→listening transition
    private var pendingBufferCount = 0
    private var responseDone = false

    // 24 kHz mono Float32 — used both as converter target and player schedule format
    private let f32_24k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Connect / Disconnect

    func connect(apiBaseURL: String, firstName: String) {
        guard rtState == .disconnected else { return }
        rtState = .connecting

        // Convert https:// → wss://, then append /realtime/ws
        let wsBase = apiBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        let nameParam = firstName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(wsBase)/realtime/ws?first_name=\(nameParam)"

        guard let url = URL(string: urlString) else {
            rtState = .disconnected; return
        }

        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        startReceiving()
        setupAudio()
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

    private func setupAudio() {
        configureAudioSession()

        let inputNode = engine.inputNode
        let hwFmt = inputNode.outputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: hwFmt, to: f32_24k)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: f32_24k)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buf, _ in
            self?.sendMicChunk(buf)
        }

        do {
            try engine.start()
            player.play()
        } catch {
            print("[RealtimeSession] engine start error: \(error)")
        }
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) {
            engine.detach(player)
        }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        // voiceChat mode enables built-in acoustic echo cancellation
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowAirPlay])
        try? s.overrideOutputAudioPort(.speaker)
        try? s.setActive(true)
    }

    // MARK: - Mic → WebSocket

    // Runs on the audio tap's background thread — keep non-@MainActor work here.
    private nonisolated func sendMicChunk(_ buffer: AVAudioPCMBuffer) {
        guard let ws = wsTask else { return }

        // Resample to 24 kHz Float32
        let ratio = 24_000.0 / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard outFrames > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: f32_24k, frameCapacity: outFrames) else { return }

        var consumed = false
        var convErr: NSError?
        inputConverter?.convert(to: outBuf, error: &convErr) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, outBuf.frameLength > 0,
              let fp = outBuf.floatChannelData?[0] else { return }

        // Float32 → Int16 PCM16
        let count = Int(outBuf.frameLength)
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            pcm[i] = Int16(max(-1, min(1, fp[i])) * 32_767)
        }

        let raw = Data(bytes: pcm, count: count * 2)
        let event = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(raw.base64EncodedString())\"}"
        ws.send(.string(event)) { _ in }
    }

    // MARK: - WebSocket → Speaker

    private func startReceiving() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:    text = ""
                }
                if !text.isEmpty {
                    Task { @MainActor in self.handleEvent(text) }
                }
                self.startReceiving()
            case .failure:
                Task { @MainActor in
                    if self.rtState != .disconnected { self.rtState = .disconnected }
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "input_audio_buffer.speech_started":
            // Barge-in: stop playback, reset pending state
            player.stop()
            pendingReplyText = ""
            pendingBufferCount = 0
            responseDone = false
            player.play()
            rtState = .listening

        case "input_audio_buffer.speech_stopped":
            rtState = .thinking

        case "response.created", "response.output_item.added":
            rtState = .thinking

        case "response.audio.delta":
            guard let delta = json["delta"] as? String,
                  let raw = Data(base64Encoded: delta),
                  raw.count >= 2 else { return }
            rtState = .speaking
            scheduleAudioChunk(raw)

        case "response.audio.done":
            responseDone = true
            checkTransitionToListening()
            let msg = pendingReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { onAssistantMessage?(msg) }
            pendingReplyText = ""

        case "response.audio_transcript.delta":
            if let d = json["delta"] as? String { pendingReplyText += d }

        case "conversation.item.input_audio_transcription.completed":
            if let t = (json["transcript"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                onUserTranscript?(t)
            }

        default:
            break
        }
    }

    private func scheduleAudioChunk(_ raw: Data) {
        let frameCount = raw.count / 2
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f32_24k,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)

        raw.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress,
                  let dst = buf.floatChannelData?[0] else { return }
            for i in 0..<frameCount { dst[i] = Float(src[i]) / 32_767.0 }
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
            rtState = .listening
            responseDone = false
        }
    }
}
