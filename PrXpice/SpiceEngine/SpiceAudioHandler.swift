import Foundation
import AVFoundation
import CoreMedia

/// Handles SPICE audio: plays back VM audio via AVAudioEngine and captures
/// mic audio to send to the VM via the SPICE record channel.
///
/// Threading rules:
/// - AVAudioEngine graph setup (connect/disconnect) only happens on main thread,
///   only while the engine is stopped.
/// - AVAudioEngine.start() / playerNode.play/stop are called on main thread.
/// - receivePlaybackData is called from GLib thread; playerNode.scheduleBuffer
///   is thread-safe. _activeFormat is guarded by formatLock.
/// - Mic capture uses AVCaptureSession on all platforms so it never touches the
///   AVAudioEngine graph, keeping playback and recording fully independent.
final class SpiceAudioHandler {
    weak var sessionManager: SpiceSessionManager?
    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // The format the playerNode is currently connected with (main thread only).
    private var connectedFormat: AVAudioFormat?

    // Active playback format — guards cross-thread access for receivePlaybackData.
    private let formatLock = NSLock()
    private var _activeFormat: AVAudioFormat?
    private var activeFormat: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _activeFormat }
        set { formatLock.lock(); defer { formatLock.unlock() }; _activeFormat = newValue }
    }

    // Only accessed on main thread
    private var engineStarted = false
    private var isRecording = false
    private var recordStartTime: Date?
    private var pendingRecordChannels: Int32 = 0
    private var pendingRecordFreq: Int32 = 0

    // Mic capture via AVCaptureSession — independent of AVAudioEngine
    private var captureSession: AVCaptureSession?
    private var captureDelegate: CaptureAudioDelegate?

    init() {
        engine.attach(playerNode)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine)
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.engineStarted else { return }
            self.onLog?("Audio: engine config changed — restarting")
            do {
                try self.engine.start()
                if self.activeFormat != nil && !self.playerNode.isPlaying {
                    self.playerNode.play()
                }
                self.onLog?("Audio: engine restarted OK")
            } catch {
                self.engineStarted = false
                self.activeFormat = nil
                self.onLog?("Audio: engine restart failed: \(error)")
            }
        }
    }

    // MARK: - Playback (VM → speaker)

    func startPlayback(channels: Int32, freq: Int32) {
        DispatchQueue.main.async { [weak self] in
            self?.doStartPlayback(channels: channels, freq: freq)
        }
    }

    private func doStartPlayback(channels: Int32, freq: Int32) {
        let ch = max(Int(channels), 1)
        let hz = Double(max(freq, 1))

        guard let swiftFmt = AVAudioFormat(standardFormatWithSampleRate: hz,
                                           channels: AVAudioChannelCount(ch)) else {
            onLog?("Audio: invalid format ch=\(channels) freq=\(freq)")
            return
        }

        let formatChanged = connectedFormat.map { $0 != swiftFmt } ?? true

        if formatChanged {
            if engineStarted {
                playerNode.stop()
                engine.stop()
                engineStarted = false
                engine.disconnectNodeOutput(playerNode)
                activeFormat = nil
                if isRecording {
                    captureSession?.stopRunning()
                    captureSession = nil
                    captureDelegate = nil
                    isRecording = false
                }
            }
            engine.connect(playerNode, to: engine.mainMixerNode, format: swiftFmt)
            connectedFormat = swiftFmt
            onLog?("Audio: connected ch=\(ch) freq=\(Int(hz))")
        }

        #if !targetEnvironment(macCatalyst)
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true)
        } catch {
            onLog?("Audio: session error: \(error)")
        }
        #endif

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

        if !playerNode.isPlaying { playerNode.play() }
        activeFormat = swiftFmt
        onLog?("Audio: playback started ch=\(ch) freq=\(Int(hz))")

        if formatChanged && !isRecording && pendingRecordChannels > 0 {
            installMicTap(channels: pendingRecordChannels, freq: pendingRecordFreq)
        }
    }

    /// Called from GLib thread — scheduleBuffer is thread-safe.
    func receivePlaybackData(_ data: UnsafePointer<UInt8>, size: Int32) {
        guard let fmt = activeFormat, size > 0 else { return }

        let ch = Int(fmt.channelCount)
        let bytesPerFrame = ch * 2
        let numFrames = Int(size) / bytesPerFrame
        guard numFrames > 0 else { return }

        let safeSize = numFrames * bytesPerFrame
        let raw = Data(bytes: data, count: safeSize)

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                          frameCapacity: AVAudioFrameCount(numFrames)) else { return }
        buf.frameLength = AVAudioFrameCount(numFrames)
        guard let floatChannels = buf.floatChannelData else { return }

        let scale = Float(1.0 / 32768.0)
        raw.withUnsafeBytes { rawBytes in
            guard let s16 = rawBytes.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for c in 0..<ch {
                let dst = floatChannels[c]
                for f in 0..<numFrames { dst[f] = Float(s16[f * ch + c]) * scale }
            }
        }

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

    // MARK: - Record (mic → VM)

    func startRecord(channels: Int32, freq: Int32) {
        onLog?("Audio: record-start ch=\(channels) freq=\(freq) — requesting mic permission")
        DispatchQueue.main.async { [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:
                self?.onLog?("Audio: mic access GRANTED")
                self?.installMicTap(channels: channels, freq: freq)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    self?.onLog?("Audio: mic access \(granted ? "GRANTED" : "DENIED")")
                    if granted {
                        DispatchQueue.main.async { self?.installMicTap(channels: channels, freq: freq) }
                    } else {
                        self?.onLog?("Audio: mic permission denied — enable in Settings → Privacy → Microphone")
                    }
                }
            default:
                #if targetEnvironment(macCatalyst)
                self?.onLog?("Audio: mic access DENIED — run: sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db \"INSERT OR REPLACE INTO access VALUES('kTCCServiceMicrophone','com.Dn0w.PrXpice',0,2,2,1,NULL,NULL,0,'UNUSED',NULL,0,strftime('%s','now'),NULL,NULL,'UNUSED',0)\"")
                #else
                self?.onLog?("Audio: mic access DENIED — enable in Settings → Privacy → Microphone")
                #endif
            }
        }
    }

    private func installMicTap(channels: Int32, freq: Int32) {
        guard !isRecording else {
            onLog?("Audio: installMicTap skipped — already recording")
            return
        }

        guard let targetFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Double(freq),
                                             channels: AVAudioChannelCount(channels),
                                             interleaved: true) else {
            onLog?("Audio: failed to create target mic format ch=\(channels) freq=\(freq)")
            return
        }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            onLog?("Audio: no capture device found")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onLog?("Audio: capture input error: \(error)")
            return
        }

        pendingRecordChannels = channels
        pendingRecordFreq = freq
        recordStartTime = Date()
        isRecording = true

        let session = AVCaptureSession()
        // Prevent AVCaptureSession from reconfiguring the audio session,
        // which would reroute output and silence AVAudioEngine playback.
        // Not needed on macOS — AVCaptureSession never reroutes audio there.
        #if !targetEnvironment(macCatalyst)
        session.automaticallyConfiguresApplicationAudioSession = false
        #endif
        if session.canAddInput(input) { session.addInput(input) }

        let audioOutput = AVCaptureAudioDataOutput()
        let delegate = CaptureAudioDelegate(targetFmt: targetFmt,
                                            onLog: { [weak self] msg in self?.onLog?(msg) },
                                            onData: { [weak self] ptr, size in
            guard let self = self, let manager = self.sessionManager else { return }
            let elapsed = UInt32((Date().timeIntervalSince(self.recordStartTime ?? Date())) * 1000)
            manager.sendRecordData(ptr, size: size, timeMs: elapsed)
        })
        audioOutput.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "mic.capture"))
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        captureSession = session
        captureDelegate = delegate
        session.startRunning()
        onLog?("Audio: mic capture started ch=\(channels) freq=\(freq)")

        // Some hardware disrupts the AVAudioEngine when capture starts.
        // Check 150ms later and restart the engine if needed.
        let wasPlayingFmt = activeFormat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.engineStarted, !self.engine.isRunning else { return }
            self.onLog?("Audio: engine stopped by capture start — restarting")
            do {
                try self.engine.start()
                if wasPlayingFmt != nil && !self.playerNode.isPlaying { self.playerNode.play() }
                self.onLog?("Audio: engine restarted after capture start")
            } catch {
                self.onLog?("Audio: engine restart failed: \(error)")
            }
        }
    }

    func stopRecord() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.captureDelegate = nil
            self.isRecording = false
            self.recordStartTime = nil
            self.pendingRecordChannels = 0
            self.pendingRecordFreq = 0
            self.onLog?("Audio: mic stopped")
        }
    }

    deinit {
        captureSession?.stopRunning()
        if engineStarted { playerNode.stop(); engine.stop() }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

private final class CaptureAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let targetFmt: AVAudioFormat
    private let onLog: (String) -> Void
    private let onData: (UnsafePointer<UInt8>, Int) -> Void
    private var converter: AVAudioConverter?
    private var loggedFirst = false

    init(targetFmt: AVAudioFormat,
         onLog: @escaping (String) -> Void,
         onData: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
        self.targetFmt = targetFmt
        self.onLog = onLog
        self.onData = onData
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        var asbd = asbdPtr.pointee
        guard let srcFmt = AVAudioFormat(streamDescription: &asbd) else { return }

        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard numFrames > 0 else { return }

        if !loggedFirst {
            loggedFirst = true
            onLog("Audio: capture CB sr=\(srcFmt.sampleRate) ch=\(srcFmt.channelCount)")
        }

        if converter == nil {
            converter = AVAudioConverter(from: srcFmt, to: targetFmt)
            guard converter != nil else {
                onLog("Audio: converter failed \(srcFmt.sampleRate)Hz->\(targetFmt.sampleRate)Hz")
                return
            }
        }
        guard let conv = converter else { return }

        guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var rawPtr: UnsafeMutablePointer<Int8>?
        var totalLen = 0
        CMBlockBufferGetDataPointer(blockBuf, atOffset: 0,
                                    lengthAtOffsetOut: nil,
                                    totalLengthOut: &totalLen,
                                    dataPointerOut: &rawPtr)
        guard let raw = rawPtr else { return }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: numFrames) else { return }
        inBuf.frameLength = numFrames

        let abl = inBuf.mutableAudioBufferList
        let numBuffers = Int(abl.pointee.mNumberBuffers)
        let firstBufPtr = withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { $0 }
        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: firstBufPtr, count: numBuffers)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        if srcFmt.isInterleaved || numBuffers == 1 {
            if let dst = buffers[0].mData {
                memcpy(dst, raw, min(Int(buffers[0].mDataByteSize), Int(numFrames) * bytesPerFrame))
            }
        } else {
            let bytesPerChannel = Int(numFrames) * bytesPerFrame
            for ch in 0..<numBuffers {
                if let dst = buffers[ch].mData {
                    memcpy(dst, UnsafeRawPointer(raw).advanced(by: ch * bytesPerChannel),
                           min(Int(buffers[ch].mDataByteSize), bytesPerChannel))
                }
            }
        }

        let outCapacity = AVAudioFrameCount(
            Double(numFrames) * Double(targetFmt.sampleRate) / srcFmt.sampleRate + 1
        )
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outCapacity) else { return }
        var inputConsumed = false
        var convError: NSError?
        conv.convert(to: outBuf, error: &convError) { _, status in
            if inputConsumed { status.pointee = .noDataNow; return nil }
            inputConsumed = true
            status.pointee = .haveData
            return inBuf
        }
        guard convError == nil, outBuf.frameLength > 0 else { return }

        let byteCount = Int(outBuf.frameLength) * Int(targetFmt.channelCount) * 2
        outBuf.int16ChannelData?[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
            onData(ptr, byteCount)
        }
    }
}
