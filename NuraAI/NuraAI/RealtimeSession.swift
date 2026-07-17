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
        // Always start from a fresh engine to avoid "already attached" crashes
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setPreferredSampleRate(24_000)
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            print("[RT] AVAudioSession setup error: \(error)")
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFmt)

        // Start engine FIRST — only then is inputNode's format reliable
        do {
            try engine.start()
        } catch {
            print("[RT] engine.start() failed: \(error)")
            return false
        }

        player.play()

        // Query format after engine is running
        let inputNode = engine.inputNode
        let hwFmt = inputNode.outputFormat(forBus: 0)
        guard hwFmt.sampleRate > 0 else {
            print("[RT] invalid input format: \(hwFmt)")
            engine.stop()
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buf, _ in
            self?.handleMicBuffer(buf)
        }

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

    private nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let ws = wsTask else { return }
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
            player.stop()
            player.play()
            pendingReplyText = ""
            pendingBufferCount = 0
            responseDone = false
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
            print("[RT] OpenAI error: \(text)")

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
