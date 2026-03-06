import Foundation
import Combine

struct VMResolution: Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }

    static let presets16x10: [VMResolution] = [
        VMResolution(width: 1280, height: 800),
        VMResolution(width: 1440, height: 900),
        VMResolution(width: 1600, height: 1000),
        VMResolution(width: 1920, height: 1200),
        VMResolution(width: 2560, height: 1600),
    ]
}

@MainActor
final class VMDisplayViewModel: ObservableObject {
    @Published private(set) var connectionState: SpiceConnectionState = .disconnected
    @Published var error: String?
    @Published var showToolbar = true
    @Published private(set) var debugLog: [String] = []

    let sessionManager = SpiceSessionManager()
    let displayHandler = SpiceDisplayHandler()
    let inputHandler = SpiceInputHandler()
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

        // Wire debug log from display handler
        displayHandler.onLog = { [weak self] msg in
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

    func handleToolbarKey(_ key: InputToolbarKey) {
        switch key {
        case .escape:
            inputHandler.keyTap(scancode: 0x01)
        case .tab:
            inputHandler.keyTap(scancode: 0x0F)
        case .ctrlAltDel:
            sendCtrlAltDel()
        case .functionKey(let num):
            // F1=0x3B, F2=0x3C, ... F10=0x44, F11=0x57, F12=0x58
            let scancode: UInt32
            if num <= 10 {
                scancode = UInt32(0x3A + num)
            } else if num == 11 {
                scancode = 0x57
            } else {
                scancode = 0x58
            }
            inputHandler.keyTap(scancode: scancode)
        case .modifier(let mod):
            let scancode: UInt32
            switch mod {
            case .ctrl: scancode = 0x1D
            case .alt: scancode = 0x38
            case .shift: scancode = 0x2A
            }
            // Toggle: if currently pressed, release; otherwise press
            // For simplicity, just send press (the toolbar button tracks active state)
            inputHandler.keyPress(scancode: scancode)
        }
    }

    func setResolution(_ resolution: VMResolution) {
        sessionManager.setDisplayResolution(width: resolution.width, height: resolution.height)
    }

    func releaseAllModifiers() {
        keyboardManager.releaseAllKeys()
    }
}
