import Foundation
import CSpiceBridge

/// Routes Swift-level input events to the SPICE session.
/// Translates touch gestures and keyboard events into SPICE protocol messages.
final class SpiceInputHandler {
    weak var sessionManager: SpiceSessionManager?

    private var currentButtonMask: UInt32 = 0

    /// Set to true for VMs that use server/relative mouse mode (e.g. macOS/Hackintosh without vdagent).
    var useRelativeMouse: Bool = false
    private var lastMousePosition: (x: Int, y: Int)? = nil

    // MARK: - Mouse

    func resetMouseTracking() {
        lastMousePosition = nil
    }

    func mouseMove(x: Int, y: Int) {
        guard let manager = sessionManager else { return }
        if useRelativeMouse {
            if let last = lastMousePosition {
                let dx = Int32(x - last.x)
                let dy = Int32(y - last.y)
                if dx != 0 || dy != 0 {
                    manager.sendMouseMotion(dx: dx, dy: dy, buttonMask: currentButtonMask)
                }
            }
            lastMousePosition = (x, y)
        } else {
            manager.sendMousePosition(
                x: Int32(x),
                y: Int32(y),
                displayId: 0,
                buttonMask: currentButtonMask
            )
        }
    }

    func mouseButtonPress(button: MouseButton) {
        let mask = button.spiceMask
        currentButtonMask |= mask
        sessionManager?.sendMouseButtonPress(button: mask, buttonMask: currentButtonMask)
    }

    func mouseButtonRelease(button: MouseButton) {
        let mask = button.spiceMask
        currentButtonMask &= ~mask
        sessionManager?.sendMouseButtonRelease(button: mask, buttonMask: currentButtonMask)
    }

    func scrollUp() {
        sessionManager?.sendMouseButtonPress(
            button: UInt32(SPICE_BRIDGE_MOUSE_BUTTON_UP.rawValue),
            buttonMask: currentButtonMask | UInt32(SPICE_BRIDGE_MOUSE_BUTTON_UP.rawValue)
        )
        sessionManager?.sendMouseButtonRelease(
            button: UInt32(SPICE_BRIDGE_MOUSE_BUTTON_UP.rawValue),
            buttonMask: currentButtonMask
        )
    }

    func scrollDown() {
        sessionManager?.sendMouseButtonPress(
            button: UInt32(SPICE_BRIDGE_MOUSE_BUTTON_DOWN.rawValue),
            buttonMask: currentButtonMask | UInt32(SPICE_BRIDGE_MOUSE_BUTTON_DOWN.rawValue)
        )
        sessionManager?.sendMouseButtonRelease(
            button: UInt32(SPICE_BRIDGE_MOUSE_BUTTON_DOWN.rawValue),
            buttonMask: currentButtonMask
        )
    }

    // MARK: - Keyboard

    func keyPress(scancode: UInt32) {
        sessionManager?.sendKeyPress(scancode: scancode)
    }

    func keyRelease(scancode: UInt32) {
        sessionManager?.sendKeyRelease(scancode: scancode)
    }

    /// Press and release a key (convenience)
    func keyTap(scancode: UInt32) {
        keyPress(scancode: scancode)
        keyRelease(scancode: scancode)
    }

    /// Send Ctrl+Alt+Delete combo
    func sendCtrlAltDel() {
        let ctrlScancode: UInt32 = 0x1D
        let altScancode: UInt32 = 0x38
        let delScancode: UInt32 = 0xE053

        keyPress(scancode: ctrlScancode)
        keyPress(scancode: altScancode)
        keyPress(scancode: delScancode)
        keyRelease(scancode: delScancode)
        keyRelease(scancode: altScancode)
        keyRelease(scancode: ctrlScancode)
    }

    enum MouseButton {
        case left, middle, right

        var spiceMask: UInt32 {
            switch self {
            case .left: return UInt32(SPICE_BRIDGE_MOUSE_BUTTON_LEFT.rawValue)
            case .middle: return UInt32(SPICE_BRIDGE_MOUSE_BUTTON_MIDDLE.rawValue)
            case .right: return UInt32(SPICE_BRIDGE_MOUSE_BUTTON_RIGHT.rawValue)
            }
        }
    }
}
