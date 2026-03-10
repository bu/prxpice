import Foundation
import Combine
import UIKit
import CSpiceBridge

/// Connection state published to the UI layer.
enum SpiceConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)
}

/// Swift wrapper around the C SPICE bridge session.
/// Manages session lifecycle, publishes connection state, and routes
/// display/input callbacks to their respective handlers.
final class SpiceSessionManager: ObservableObject {
    @Published private(set) var connectionState: SpiceConnectionState = .disconnected

    private var bridgeSession: OpaquePointer? // SpiceBridgeSession*
    private let glibLoop = GLibRunLoopIntegration()

    var displayHandler: SpiceDisplayHandler?
    var inputHandler: SpiceInputHandler?
    var audioHandler: SpiceAudioHandler?

    // Prevent dealloc while callbacks are active
    private var retainedSelf: Unmanaged<SpiceSessionManager>?

    // Reconnection
    private var lastConfig: SpiceConfig?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?

    // App lifecycle
    private var wasConnectedBeforeBackground = false

    init() {
        setupLifecycleObservers()
    }

    deinit {
        reconnectTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }

    /// Connects to a SPICE server with the given configuration.
    func connect(config: SpiceConfig) {
        guard connectionState == .disconnected || connectionState != .connecting else { return }
        lastConfig = config
        reconnectAttempts = 0

        // Retain self for C callback lifetime
        retainedSelf = Unmanaged.passRetained(self)
        let context = retainedSelf!.toOpaque()

        // Set up C callbacks
        var callbacks = SpiceBridgeCallbacks()
        callbacks.context = context
        callbacks.on_state_changed = { ctx, state in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.handleStateChange(state)
        }
        callbacks.on_display_create = { ctx, surface in
            guard let ctx = ctx, let surface = surface else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.displayHandler?.handleDisplayCreate(surface: surface.pointee)
        }
        callbacks.on_display_invalidate = { ctx, surfaceId, rect, data, stride in
            guard let ctx = ctx, let rect = rect else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.displayHandler?.handleDisplayInvalidate(
                surfaceId: surfaceId,
                rect: rect.pointee,
                data: data,
                stride: stride
            )
        }
        callbacks.on_display_destroy = { ctx, surfaceId in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.displayHandler?.handleDisplayDestroy(surfaceId: surfaceId)
        }
        callbacks.on_debug = { ctx, msg in
            guard let ctx = ctx, let msg = msg else { return }
            let str = String(cString: msg)
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.displayHandler?.onLog?("C: \(str)")
        }
        callbacks.on_playback_start = { ctx, channels, freq in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.audioHandler?.startPlayback(channels: channels, freq: freq)
        }
        callbacks.on_playback_data = { ctx, data, size in
            guard let ctx = ctx, let data = data else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.audioHandler?.receivePlaybackData(data, size: size)
        }
        callbacks.on_playback_stop = { ctx in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.audioHandler?.stopPlayback()
        }
        callbacks.on_record_start = { ctx, channels, freq in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.audioHandler?.startRecord(channels: channels, freq: freq)
        }
        callbacks.on_record_stop = { ctx in
            guard let ctx = ctx else { return }
            let manager = Unmanaged<SpiceSessionManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.audioHandler?.stopRecord()
        }

        // Create session
        bridgeSession = spice_bridge_session_new(&callbacks)
        guard let session = bridgeSession else {
            updateState(.error("Failed to create SPICE session"))
            releaseRetainedSelf()
            return
        }

        // Start GLib main loop thread
        glibLoop.start(session: session)

        // Connect
        let success = spice_bridge_connect(
            session,
            config.host,
            Int32(config.port),
            Int32(config.tlsPort ?? 0),
            config.password,
            config.ca,
            config.hostSubject,
            config.proxy
        )

        if !success {
            updateState(.error("Connection failed"))
            disconnect()
        }
    }

    /// Disconnects the current session.
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        lastConfig = nil // Prevent auto-reconnect on user-initiated disconnect

        guard let session = bridgeSession else { return }
        bridgeSession = nil // nil immediately so no further C calls use it

        updateState(.disconnecting)

        // Disconnect SPICE (closes relay listener, signals GLib quit)
        spice_bridge_disconnect(session)

        // Wait for GLib thread + free session on background — never block main thread
        let glibLoopRef = glibLoop
        let retained = retainedSelf
        retainedSelf = nil

        DispatchQueue.global(qos: .utility).async {
            glibLoopRef.stopAndWait(session: session)
            spice_bridge_session_free(session)
            retained?.release()
        }

        updateState(.disconnected)
    }

    /// Sends a key press scancode to the VM.
    func sendKeyPress(scancode: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_key_press(session, scancode)
    }

    /// Sends a key release scancode to the VM.
    func sendKeyRelease(scancode: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_key_release(session, scancode)
    }

    /// Sends absolute mouse position to the VM.
    func sendMousePosition(x: Int32, y: Int32, displayId: Int32, buttonMask: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_mouse_position(session, x, y, displayId, buttonMask)
    }

    /// Sends relative mouse motion to the VM.
    func sendMouseMotion(dx: Int32, dy: Int32, buttonMask: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_mouse_motion(session, dx, dy, buttonMask)
    }

    /// Sends a mouse button press.
    func sendMouseButtonPress(button: UInt32, buttonMask: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_mouse_button_press(session, button, buttonMask)
    }

    /// Sends a mouse button release.
    func sendMouseButtonRelease(button: UInt32, buttonMask: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_mouse_button_release(session, button, buttonMask)
    }

    /// Sends mic audio data to the VM record channel.
    func sendRecordData(_ data: UnsafePointer<UInt8>, size: Int, timeMs: UInt32) {
        guard let session = bridgeSession else { return }
        spice_bridge_record_send_data(session, data, size, timeMs)
    }

    /// Attempts to reconnect using the last config.
    func attemptReconnect() {
        guard let config = lastConfig, reconnectAttempts < maxReconnectAttempts else {
            updateState(.error("Reconnection failed after \(maxReconnectAttempts) attempts"))
            return
        }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0) // Exponential backoff, max 30s
        Log.spice.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect(config: config)
        }
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        wasConnectedBeforeBackground = (connectionState == .connected)
        // Keep connection alive briefly for fast app switching
        // iOS gives ~30s of background time
        Log.spice.info("App backgrounded, connection state: \(String(describing: self.connectionState))")
    }

    @objc private func appWillEnterForeground() {
        Log.spice.info("App foregrounded, was connected: \(self.wasConnectedBeforeBackground)")
        if wasConnectedBeforeBackground && connectionState != .connected {
            attemptReconnect()
        }
    }

    // MARK: - Private

    private func handleStateChange(_ cState: SpiceBridgeState) {
        let newState: SpiceConnectionState
        switch cState {
        case SPICE_BRIDGE_STATE_DISCONNECTED:
            newState = .disconnected
        case SPICE_BRIDGE_STATE_CONNECTING:
            newState = .connecting
        case SPICE_BRIDGE_STATE_CONNECTED:
            newState = .connected
            reconnectAttempts = 0
        case SPICE_BRIDGE_STATE_DISCONNECTING:
            newState = .disconnecting
        case SPICE_BRIDGE_STATE_ERROR:
            newState = .error("Connection error")
        default:
            newState = .disconnected
        }
        updateState(newState)

        // Auto-reconnect on unexpected disconnect (not user-initiated)
        if cState == SPICE_BRIDGE_STATE_ERROR || (cState == SPICE_BRIDGE_STATE_DISCONNECTED && lastConfig != nil && reconnectAttempts == 0) {
            DispatchQueue.main.async { [weak self] in
                self?.attemptReconnect()
            }
        }
    }

    private func updateState(_ state: SpiceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = state
        }
    }

    private func releaseRetainedSelf() {
        retainedSelf?.release()
        retainedSelf = nil
    }
}
