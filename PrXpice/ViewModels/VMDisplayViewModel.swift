import Foundation
import Combine

@MainActor
final class VMDisplayViewModel: ObservableObject {
    @Published private(set) var connectionState: SpiceConnectionState = .disconnected
    @Published var error: String?
    @Published var showToolbar = true
    @Published private(set) var debugLog: [String] = []

    /// True while keyboard input is captured by the VM (Mac Catalyst only).
    /// Driven by `MetalDisplayViewController` via the coordinator callback.
    @Published var isCaptureModeActive: Bool = false

    let sessionManager = SpiceSessionManager()
    let displayHandler = SpiceDisplayHandler()
    let inputHandler = SpiceInputHandler()
    let audioHandler = SpiceAudioHandler()
    let touchMapper = TouchToMouseMapper()
    let keyboardManager = KeyboardManager()

    private var cancellables = Set<AnyCancellable>()
    private let vm: VMInfo

    init(vm: VMInfo) {
        self.vm = vm

        // Wire up components
        inputHandler.sessionManager = sessionManager
        touchMapper.inputHandler = inputHandler
        keyboardManager.inputHandler = inputHandler
        sessionManager.displayHandler = displayHandler
        sessionManager.inputHandler = inputHandler
        sessionManager.audioHandler = audioHandler
        audioHandler.sessionManager = sessionManager

        // Wire debug log from display handler and audio handler
        displayHandler.onLog = { [weak self] msg in
            DispatchQueue.main.async { self?.appendDebug(msg) }
        }
        audioHandler.onLog = { [weak self] msg in
            CrashLogger.log(msg)
            DispatchQueue.main.async { self?.appendDebug(msg) }
        }

        // Observe connection state
        sessionManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.appendDebug("State: \(state)")
                if case .error(let msg) = state {
                    self?.error = msg
                }
            }
            .store(in: &cancellables)
    }

    func connect(config: SpiceConfig) {
        error = nil
        appendDebug("host:\(config.host) port:\(config.port)")
        appendDebug("tls:\(config.tlsPort ?? -1) proxy:\(config.proxy ?? "nil")")
        appendDebug("pw:\(config.password != nil ? "set" : "nil") ca:\(config.ca != nil ? "set" : "nil")")
        sessionManager.connect(config: config)
    }

    func appendDebug(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog.append("[\(ts)] \(msg)")
        if debugLog.count > 500 { debugLog.removeFirst(100) } // keep up to 500 entries
    }

    func disconnect() {
        sessionManager.disconnect()
    }

    func sendCtrlAltDel() {
        inputHandler.sendCtrlAltDel()
    }

    func releaseAllModifiers() {
        keyboardManager.releaseAllKeys()
    }
}
