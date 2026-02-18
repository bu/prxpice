import Foundation
import Combine

@MainActor
final class VMDisplayViewModel: ObservableObject {
    @Published private(set) var connectionState: SpiceConnectionState = .disconnected
    @Published var error: String?
    @Published var showToolbar = true

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

        // Observe connection state
        sessionManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                if case .error(let msg) = state {
                    self?.error = msg
                }
            }
            .store(in: &cancellables)
    }

    func connect(config: SpiceConfig) {
        error = nil
        sessionManager.connect(config: config)
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

    func releaseAllModifiers() {
        keyboardManager.releaseAllKeys()
    }
}
