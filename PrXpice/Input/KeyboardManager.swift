import UIKit

/// Translates physical keyboard events (from hardware keyboards connected to
/// iPad/iPhone) into SPICE scancodes using UIKey HID usage codes.
final class KeyboardManager {
    weak var inputHandler: SpiceInputHandler?

    // Track pressed keys to handle key repeat correctly
    private var pressedKeys: Set<UInt32> = []

    /// Called from pressesBegan in the view controller.
    func handleKeyDown(_ key: UIKey) {
        guard let scancode = ScancodeMap.xtScancode(for: key.keyCode) else { return }

        // Avoid sending duplicate key presses (key repeat)
        guard !pressedKeys.contains(scancode) else { return }

        pressedKeys.insert(scancode)
        inputHandler?.keyPress(scancode: scancode)
    }

    /// Called from pressesEnded in the view controller.
    func handleKeyUp(_ key: UIKey) {
        guard let scancode = ScancodeMap.xtScancode(for: key.keyCode) else { return }

        pressedKeys.remove(scancode)
        inputHandler?.keyRelease(scancode: scancode)
    }

    /// Release all currently pressed keys.
    /// Call this when the app loses focus or the keyboard is disconnected.
    func releaseAllKeys() {
        for scancode in pressedKeys {
            inputHandler?.keyRelease(scancode: scancode)
        }
        pressedKeys.removeAll()
    }
}
