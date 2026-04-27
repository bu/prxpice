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

    /// Converts a text string from the software keyboard into SPICE key events.
    func handleText(_ text: String) {
        let shift: UInt32 = 0x2A
        for char in text {
            if char == "\u{08}" || char == "\u{7F}" {
                inputHandler?.keyPress(scancode: 0x0E)
                inputHandler?.keyRelease(scancode: 0x0E)
                continue
            }
            guard let (base, needsShift) = ScancodeMap.sequence(for: char) else { continue }
            if needsShift { inputHandler?.keyPress(scancode: shift) }
            inputHandler?.keyPress(scancode: base)
            inputHandler?.keyRelease(scancode: base)
            if needsShift { inputHandler?.keyRelease(scancode: shift) }
        }
    }

    /// Release all currently pressed keys.
    /// Call this when the app loses focus or the keyboard is disconnected.
    func releaseAllKeys() {
        for scancode in pressedKeys {
            inputHandler?.keyRelease(scancode: scancode)
        }
        pressedKeys.removeAll()
    }

    /// Replays a `UIKeyCommand` as a discrete press/release pair plus surrounding
    /// modifier press/release. Used by the Mac Catalyst capture mode, where
    /// `UIKeyCommand` action delivery does not generate matching `pressesBegan`/
    /// `pressesEnded` events.
    func sendKeyCommandTap(input: String, flags: UIKeyModifierFlags) {
        guard let inputHandler else { return }
        guard let base = CaptureKeyCommandTable.baseScancode(forInput: input) else { return }

        let modifiers = CaptureKeyCommandTable.modifierScancodes(for: flags)
        for mod in modifiers {
            inputHandler.keyPress(scancode: mod)
        }
        inputHandler.keyPress(scancode: base)
        inputHandler.keyRelease(scancode: base)
        for mod in modifiers.reversed() {
            inputHandler.keyRelease(scancode: mod)
        }
    }
}
