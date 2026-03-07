import Foundation
import AVFoundation
import CSpiceBridge

/// Handles SPICE audio: plays back VM audio via AVAudioEngine and captures
/// iPad mic audio to send to the VM via the SPICE record channel.
///
/// Threading rules:
/// - AVAudioEngine node graph setup (connect/disconnect) happens ONCE in init
///   on the main thread, before the engine starts. It is never changed again,
///   which eliminates NSException crashes from reconnecting nodes.
/// - AVAudioEngine.start() and playerNode.play/stop are called on main thread.
/// - receivePlaybackData is called from GLib thread; AVAudioConverter and
///   AVAudioPlayerNode.scheduleBuffer are thread-safe.
/// - _converter / _sourceFormat are guarded by converterLock.
final class SpiceAudioHandler {
    weak var sessionManager: SpiceSessionManager?
    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // Fixed pipeline format — playerNode is connected with this format once in init.
    // SPICE audio (any rate/channels) is converted to this format before scheduling.
    private let pipelineFormat: AVAudioFormat

    // Converter: SPICE source format → pipelineFormat
    // Written on main thread, read on GLib thread.
    private let converterLock = NSLock()
    private var _converter: AVAudioConverter?
    private var _sourceFormat: AVAudioFormat?

    // Only accessed on main thread
    private var engineStarted = false
    private var isRecording = false
    private var recordStartTime: Date?

    init() {
        // 48 kHz stereo Float32 non-interleaved — compatible with all iOS hardware.
        // AVAudioEngine inserts its own hardware-rate converter automatically if needed.
        pipelineFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        // Connect the graph ONCE here, before the engine ever starts.
        // Never call engine.connect / engine.disconnectNodeOutput again —
        // doing so while the engine is running can throw uncatchable NSExceptions.
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pipelineFormat)
    }

    // MARK: - Playback (VM → iPad speaker)

    func startPlayback(channels: Int32, freq: Int32) {
        DispatchQueue.main.async { [weak self] in
            self?.doStartPlayback(channels: channels, freq: freq)
        }
    }

    private func doStartPlayback(channels: Int32, freq: Int32) {
        // SPICE delivers S16 interleaved PCM
        guard let srcFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(max(freq, 1)),
            channels: AVAudioChannelCount(max(channels, 1)),
            interleaved: true
        ) else {
            onLog?("Audio: invalid format ch=\(channels) freq=\(freq)")
            return
        }

        // Rebuild converter only when the source format changes
        converterLock.lock()
        let sameFormat = (_sourceFormat == srcFmt)
        converterLock.unlock()

        if !sameFormat {
            let conv = AVAudioConverter(from: srcFmt, to: pipelineFormat)
            converterLock.lock()
            _sourceFormat = srcFmt
            _converter = conv
            converterLock.unlock()
            onLog?("Audio: converter ready ch=\(channels) freq=\(freq)")
        }

        // Activate audio session (playback-only — no mic permission needed)
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback)
            try s.setActive(true)
        } catch {
            onLog?("Audio: session error: \(error)")
        }

        // Start the engine once; it stays running for the session lifetime
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
        onLog?("Audio: playback started ch=\(channels) freq=\(freq)")
    }

    /// Called from GLib thread — AVAudioConverter and scheduleBuffer are thread-safe.
    func receivePlaybackData(_ data: UnsafePointer<UInt8>, size: Int32) {
        converterLock.lock()
        let converter = _converter
        let srcFmt = _sourceFormat
        converterLock.unlock()

        guard let conv = converter, let fmt = srcFmt, size > 0 else { return }

        let bytesPerFrame = Int(fmt.channelCount) * 2  // S16 = 2 bytes/sample
        let numFrames = Int(size) / bytesPerFrame
        guard numFrames > 0 else { return }

        // Source buffer — S16 interleaved
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(numFrames)) else { return }
        srcBuf.frameLength = AVAudioFrameCount(numFrames)

        // Copy raw PCM bytes directly into the buffer
        // For interleaved S16, int16ChannelData[0] points to the single interleaved block
        if let dst = srcBuf.int16ChannelData?[0] {
            UnsafeMutableRawPointer(dst).copyMemory(from: data, byteCount: Int(size))
        }

        // Output buffer — pipelineFormat (Float32 non-interleaved, 48 kHz stereo)
        let outCapacity = AVAudioFrameCount(
            Double(numFrames) * pipelineFormat.sampleRate / fmt.sampleRate + 1.0
        )
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: pipelineFormat,
                                             frameCapacity: outCapacity) else { return }

        var inputConsumed = false
        conv.convert(to: dstBuf, error: nil) { _, status in
            if inputConsumed { status.pointee = .noDataNow; return nil }
            inputConsumed = true
            status.pointee = .haveData
            return srcBuf
        }

        if dstBuf.frameLength > 0 {
            playerNode.scheduleBuffer(dstBuf)
        }
    }

    func stopPlayback() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.converterLock.lock()
            self._converter = nil
            self._sourceFormat = nil
            self.converterLock.unlock()
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

        let inputNode = engine.inputNode
        let inputFmt = inputNode.outputFormat(forBus: 0)

        guard inputFmt.sampleRate > 0 else {
            onLog?("Audio: mic input format invalid")
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

        // Switch to playAndRecord now that permission is granted
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch {
            onLog?("Audio: playAndRecord session error: \(error)")
        }

        if !engineStarted {
            do {
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
            // Restore playback-only session if playback is still active
            self.converterLock.lock()
            let hasPlayback = self._converter != nil
            self.converterLock.unlock()
            if hasPlayback {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
            }
        }
    }

    deinit {
        if isRecording { engine.inputNode.removeTap(onBus: 0) }
        if engineStarted { playerNode.stop(); engine.stop() }
    }
}
