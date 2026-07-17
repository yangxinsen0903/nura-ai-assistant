import AVFoundation
import Foundation

@MainActor
final class RealtimeSession: ObservableObject {

    enum RTState {
        case disconnected, connecting, listening, thinking, speaking
    }

    @Published var rtState: RTState = .disconnected

    var onUserTranscript: ((String) -> Void)?
    var onAssistantMessage: ((String) -> Void)?

    // nonisolated(unsafe): accessed from the real-time audio tap thread without
    // actor hops that would introduce latency. Set/cleared only on main actor.
    nonisolated(unsafe) private var wsTask: URLSessionWebSocketTask?
    nonisolated(unsafe) private var inputConverter: AVAudioConverter?
    nonisolated(unsafe) private let f32_24k: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var pendingReplyText = ""
    private var pendingBufferCount = 0
    private var responseDone = false

    // MARK: - Connect / Disconnect

    func connect(apiBaseURL: String, firstName: String) {
        guard rtState == .disconnected else { return }
        rtState = .connecting

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
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowAirPlay])
        try? s.overrideOutputAudioPort(.speaker)
        try? s.setActive(true)

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

    // MARK: - Mic → WebSocket
    // Runs on the audio tap thread. Accesses nonisolated(unsafe) properties.
    private nonisolated func sendMicChunk(_ buffer: AVAudioPCMBuffer) {
        guard let ws = wsTask else { return }

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

        let count = Int(outBuf.frameLength)
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            pcm[i] = Int16(max(-1.0, min(1.0, fp[i])) * 32_767)
        }

        let raw = Data(bytes: pcm, count: count * 2)
        let event = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(raw.base64EncodedString())\"}"
        ws.send(.string(event)) { _ in }
    }

    // MARK: - WebSocket → Main Actor

    private func startReceiving() {
        wsTask?.receive { [weak self] result in
            // Always hop to MainActor so all self access is actor-isolated
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
                case .failure:
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
