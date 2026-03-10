import Foundation
import AVFoundation
import CSpiceBridge

/// Handles SPICE audio: plays back VM audio via AVAudioEngine and captures
/// iPad mic audio to send to the VM via the SPICE record channel.
///
/// Threading rules:
/// - AVAudioEngine graph setup (connect/disconnect) only happens on main thread,
///   only while the engine is stopped.
/// - AVAudioEngine.start() / playerNode.play/stop are called on main thread.
/// - receivePlaybackData is called from GLib thread; playerNode.scheduleBuffer
///   is thread-safe. _activeFormat is guarded by formatLock.
/// - Audio session is always .playAndRecord + .defaultToSpeaker so the category
///   never changes while the engine is running (avoiding AVAudioEngineConfigurationChange).
final class SpiceAudioHandler {
    weak var sessionManager: SpiceSessionManager?
    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // The format the playerNode is currently connected with.
    // Written on main thread only; read on main thread only.
    private var connectedFormat: AVAudioFormat?

    // Active playback format — guards cross-thread access for receivePlaybackData.
    private let formatLock = NSLock()
    private var _activeFormat: AVAudioFormat?   // set on main after engine ready
    private var activeFormat: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _activeFormat }
        set { formatLock.lock(); defer { formatLock.unlock() }; _activeFormat = newValue }
    }

    // Only accessed on main thread
    private var engineStarted = false
    private var isRecording = false
    private var recordStartTime: Date?

    init() {
        engine.attach(playerNode)
        // Do NOT connect the playerNode yet — we connect in doStartPlayback once
        // we know the actual SPICE format. Connecting in init would require a
        // fixed format guess and possibly a costly reconnect later.
    }

    // MARK: - Playback (VM → iPad speaker)

    func startPlayback(channels: Int32, freq: Int32) {
        DispatchQueue.main.async { [weak self] in
            self?.doStartPlayback(channels: channels, freq: freq)
        }
    }

    private func doStartPlayback(channels: Int32, freq: Int32) {
        let ch  = max(Int(channels), 1)
        let hz  = Double(max(freq, 1))

        // Float32 non-interleaved — AVAudioPlayerNode's native format.
        // AVAudioEngine routes this to hardware, inserting sample-rate conversion if needed.
        guard let swiftFmt = AVAudioFormat(standardFormatWithSampleRate: hz,
                                           channels: AVAudioChannelCount(ch)) else {
            onLog?("Audio: invalid format ch=\(channels) freq=\(freq)")
            return
        }

        let formatChanged = connectedFormat.map { $0 != swiftFmt } ?? true

        if formatChanged {
            // Stop engine and tear down old graph before reconnecting.
            if engineStarted {
                playerNode.stop()
                engine.stop()
                engineStarted = false
                engine.disconnectNodeOutput(playerNode)
                activeFormat = nil
            }
            engine.connect(playerNode, to: engine.mainMixerNode, format: swiftFmt)
            connectedFormat = swiftFmt
            onLog?("Audio: connected ch=\(ch) freq=\(Int(hz))")
        }

        // Always .playAndRecord + .defaultToSpeaker so the category never needs to
        // change when a record channel opens — prevents AVAudioEngineConfigurationChange.
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord,
                              mode: .default,
                              options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch {
            onLog?("Audio: session error: \(error)")
        }

        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
                onLog?("Audio: engine started")
            } catch {
                onLog?("Audio: engine start failed: \(error)")
                return
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        // Publish format to GLib thread after everything is ready
        activeFormat = swiftFmt
        onLog?("Audio: playback started ch=\(ch) freq=\(Int(hz))")
    }

    /// Called from GLib thread — scheduleBuffer is thread-safe.
    /// Converts S16 interleaved PCM → Float32 non-interleaved and schedules it.
    func receivePlaybackData(_ data: UnsafePointer<UInt8>, size: Int32) {
        guard let fmt = activeFormat, size > 0 else { return }

        let ch        = Int(fmt.channelCount)
        let bytesPerFrame = ch * 2  // S16 = 2 bytes/sample
        let numFrames = Int(size) / bytesPerFrame
        guard numFrames > 0 else { return }

        // Copy raw bytes immediately — the C buffer is borrowed and may be
        // reused by libspice after this callback returns.
        let safeSize = numFrames * bytesPerFrame
        let raw = Data(bytes: data, count: safeSize)

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                          frameCapacity: AVAudioFrameCount(numFrames)) else { return }
        buf.frameLength = AVAudioFrameCount(numFrames)

        guard let floatChannels = buf.floatChannelData else { return }

        // S16 interleaved → Float32 non-interleaved conversion
        let scale = Float(1.0 / 32768.0)
        raw.withUnsafeBytes { rawBytes in
            guard let s16 = rawBytes.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for c in 0..<ch {
                let dst = floatChannels[c]
                for f in 0..<numFrames {
                    dst[f] = Float(s16[f * ch + c]) * scale
                }
            }
        }

        // Only schedule if player is still active
        guard playerNode.isPlaying else { return }
        playerNode.scheduleBuffer(buf)
    }

    func stopPlayback() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.activeFormat = nil
            self.onLog?("Audio: playback stopped")
        }
    }

    // MARK: - Record (iPad mic → VM)

    func startRecord(channels: Int32, freq: Int32) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.onLog?("Audio: mic permission denied")
                return
            }
            DispatchQueue.main.async { self.installMicTap(channels: channels, freq: freq) }
        }
    }

    private func installMicTap(channels: Int32, freq: Int32) {
        guard !isRecording else { return }

        // Audio session is already .playAndRecord (set in doStartPlayback) —
        // no category change needed here, so AVAudioEngineConfigurationChange is not fired.
        let inputNode = engine.inputNode
        let inputFmt  = inputNode.outputFormat(forBus: 0)

        guard inputFmt.sampleRate > 0 else {
            onLog?("Audio: mic input format invalid (sampleRate=0)")
            return
        }
        guard let targetFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Double(freq),
                                             channels: AVAudioChannelCount(channels),
                                             interleaved: true),
              let converter = AVAudioConverter(from: inputFmt, to: targetFmt) else {
            onLog?("Audio: failed to create mic converter")
            return
        }

        // Start engine if not running (e.g. record channel opened before playback)
        if !engineStarted {
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playAndRecord, mode: .default,
                                  options: [.defaultToSpeaker, .allowBluetooth])
                try s.setActive(true)
                try engine.start()
                engineStarted = true
            } catch {
                onLog?("Audio: engine start for mic failed: \(error)")
                return
            }
        }

        recordStartTime = Date()
        isRecording = true

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFmt) { [weak self] inBuffer, _ in
            guard let self = self, let manager = self.sessionManager else { return }

            let outCapacity = AVAudioFrameCount(
                Double(inBuffer.frameLength) * Double(freq) / inputFmt.sampleRate + 1
            )
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt,
                                                    frameCapacity: outCapacity) else { return }
            var inputConsumed = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                if inputConsumed { status.pointee = .noDataNow; return nil }
                inputConsumed = true
                status.pointee = .haveData
                return inBuffer
            }
            guard convError == nil, outBuffer.frameLength > 0 else { return }

            let byteCount = Int(outBuffer.frameLength) * Int(targetFmt.channelCount) * 2
            let elapsedMs = UInt32((Date().timeIntervalSince(self.recordStartTime ?? Date())) * 1000)
            outBuffer.int16ChannelData?[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
                manager.sendRecordData(ptr, size: byteCount, timeMs: elapsedMs)
            }
        }
        onLog?("Audio: mic started ch=\(channels) freq=\(freq)")
    }

    func stopRecord() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.isRecording = false
            self.recordStartTime = nil
            self.onLog?("Audio: mic stopped")
        }
    }

    deinit {
        if isRecording { engine.inputNode.removeTap(onBus: 0) }
        if engineStarted { playerNode.stop(); engine.stop() }
    }
}
