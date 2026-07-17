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

    // nonisolated(unsafe): read from the real-time audio tap thread.
    // Written only on MainActor before the tap starts.
    nonisolated(unsafe) private var wsTask: URLSessionWebSocketTask?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // 24 kHz Float32 mono — output format for both resampled mic and playback
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

        // Request mic permission before touching audio hardware —
        // input format is 0 Hz until permission is granted.
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
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.allowBluetooth, .allowAirPlay])
        try? session.setPreferredSampleRate(24_000)   // ask hardware for 24 kHz
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true)

        let inputNode = engine.inputNode
        // Query format AFTER session is active — sampleRate is valid now
        let hwFmt = inputNode.outputFormat(forBus: 0)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFmt)

        // Install tap in the hardware format; we resample manually in the callback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buf, _ in
            self?.handleMicBuffer(buf)
        }

        do {
            try engine.start()
            player.play()
        } catch {
            print("[RT] engine start error: \(error)")
        }
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
    }

    // MARK: - Mic → WebSocket
    // Called on the real-time audio thread. No MainActor hops allowed.

    private nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let ws = wsTask else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let src = buffer.floatChannelData?[0] else { return }

        let srcRate = buffer.format.sampleRate
        guard srcRate > 0 else { return }

        // Resample to 24 kHz via linear interpolation, then convert Float32 → Int16
        let step    = srcRate / 24_000.0
        let outLen  = max(1, Int(Double(frameCount) / step))
        var pcm16   = [Int16](repeating: 0, count: outLen)

        for i in 0..<outLen {
            let pos  = Double(i) * step
            let lo   = Int(pos)
            let hi   = min(lo + 1, frameCount - 1)
            let frac = Float(pos - Double(lo))
            let s    = src[lo] + frac * (src[hi] - src[lo])
            let clamped = max(-32_767, min(32_767, Int32(s * 32_767)))
            pcm16[i] = Int16(clamped)
        }

        let raw   = Data(bytes: pcm16, count: pcm16.count * 2)
        let event = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(raw.base64EncodedString())\"}"
        ws.send(.string(event)) { _ in }
    }

    // MARK: - WebSocket → Main Actor

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
                    print("[RT] WebSocket error: \(err)")
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

        case "error":
            print("[RT] OpenAI error event: \(text)")

        default:
            break
        }
    }

    // MARK: - Playback

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
