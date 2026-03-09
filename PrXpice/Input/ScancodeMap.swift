import UIKit

/// Maps UIKey HID usage codes to PC XT scancodes for the SPICE protocol.
/// SPICE uses AT set 1 (XT) scancodes. Extended keys use 0xE0xx encoding.
enum ScancodeMap {
    /// Converts a UIKey's keyCode (HID usage) to a SPICE XT scancode.
    /// Returns nil for unmappable keys.
    static func xtScancode(for keyCode: UIKeyboardHIDUsage) -> UInt32? {
        return hidToXT[keyCode]
    }

    // MARK: - Software keyboard character input

    /// Returns the base scancode and whether Shift must be held to produce the character (US QWERTY).
    static func sequence(for char: Character) -> (base: UInt32, shift: Bool)? {
        charToXT[char]
    }

    private static let charToXT: [Character: (base: UInt32, shift: Bool)] = [
        "a": (0x1E,false),"b": (0x30,false),"c": (0x2E,false),"d": (0x20,false),
        "e": (0x12,false),"f": (0x21,false),"g": (0x22,false),"h": (0x23,false),
        "i": (0x17,false),"j": (0x24,false),"k": (0x25,false),"l": (0x26,false),
        "m": (0x32,false),"n": (0x31,false),"o": (0x18,false),"p": (0x19,false),
        "q": (0x10,false),"r": (0x13,false),"s": (0x1F,false),"t": (0x14,false),
        "u": (0x16,false),"v": (0x2F,false),"w": (0x11,false),"x": (0x2D,false),
        "y": (0x15,false),"z": (0x2C,false),
        "A": (0x1E,true), "B": (0x30,true), "C": (0x2E,true), "D": (0x20,true),
        "E": (0x12,true), "F": (0x21,true), "G": (0x22,true), "H": (0x23,true),
        "I": (0x17,true), "J": (0x24,true), "K": (0x25,true), "L": (0x26,true),
        "M": (0x32,true), "N": (0x31,true), "O": (0x18,true), "P": (0x19,true),
        "Q": (0x10,true), "R": (0x13,true), "S": (0x1F,true), "T": (0x14,true),
        "U": (0x16,true), "V": (0x2F,true), "W": (0x11,true), "X": (0x2D,true),
        "Y": (0x15,true), "Z": (0x2C,true),
        "1": (0x02,false),"2": (0x03,false),"3": (0x04,false),"4": (0x05,false),
        "5": (0x06,false),"6": (0x07,false),"7": (0x08,false),"8": (0x09,false),
        "9": (0x0A,false),"0": (0x0B,false),
        "!": (0x02,true), "@": (0x03,true), "#": (0x04,true), "$": (0x05,true),
        "%": (0x06,true), "^": (0x07,true), "&": (0x08,true), "*": (0x09,true),
        "(": (0x0A,true), ")": (0x0B,true),
        "-": (0x0C,false),"_": (0x0C,true), "=": (0x0D,false),"+": (0x0D,true),
        "[": (0x1A,false),"{": (0x1A,true), "]": (0x1B,false),"}": (0x1B,true),
        "\\": (0x2B,false),"|": (0x2B,true),";": (0x27,false),":": (0x27,true),
        "'": (0x28,false),"\"": (0x28,true),"`": (0x29,false),"~": (0x29,true),
        ",": (0x33,false),"<": (0x33,true), ".": (0x34,false),">": (0x34,true),
        "/": (0x35,false),"?": (0x35,true),
        " ": (0x39,false),"\t": (0x0F,false),"\n": (0x1C,false),"\r": (0x1C,false),
    ]

    // Complete HID usage → XT scancode mapping
    private static let hidToXT: [UIKeyboardHIDUsage: UInt32] = [
        // Letters
        .keyboardA: 0x1E,
        .keyboardB: 0x30,
        .keyboardC: 0x2E,
        .keyboardD: 0x20,
        .keyboardE: 0x12,
        .keyboardF: 0x21,
        .keyboardG: 0x22,
        .keyboardH: 0x23,
        .keyboardI: 0x17,
        .keyboardJ: 0x24,
        .keyboardK: 0x25,
        .keyboardL: 0x26,
        .keyboardM: 0x32,
        .keyboardN: 0x31,
        .keyboardO: 0x18,
        .keyboardP: 0x19,
        .keyboardQ: 0x10,
        .keyboardR: 0x13,
        .keyboardS: 0x1F,
        .keyboardT: 0x14,
        .keyboardU: 0x16,
        .keyboardV: 0x2F,
        .keyboardW: 0x11,
        .keyboardX: 0x2D,
        .keyboardY: 0x15,
        .keyboardZ: 0x2C,

        // Numbers
        .keyboard1: 0x02,
        .keyboard2: 0x03,
        .keyboard3: 0x04,
        .keyboard4: 0x05,
        .keyboard5: 0x06,
        .keyboard6: 0x07,
        .keyboard7: 0x08,
        .keyboard8: 0x09,
        .keyboard9: 0x0A,
        .keyboard0: 0x0B,

        // Special keys
        .keyboardReturnOrEnter: 0x1C,
        .keyboardEscape: 0x01,
        .keyboardDeleteOrBackspace: 0x0E,
        .keyboardTab: 0x0F,
        .keyboardSpacebar: 0x39,
        .keyboardHyphen: 0x0C,
        .keyboardEqualSign: 0x0D,
        .keyboardOpenBracket: 0x1A,
        .keyboardCloseBracket: 0x1B,
        .keyboardBackslash: 0x2B,
        .keyboardSemicolon: 0x27,
        .keyboardQuote: 0x28,
        .keyboardGraveAccentAndTilde: 0x29,
        .keyboardComma: 0x33,
        .keyboardPeriod: 0x34,
        .keyboardSlash: 0x35,
        .keyboardCapsLock: 0x3A,

        // Function keys
        .keyboardF1: 0x3B,
        .keyboardF2: 0x3C,
        .keyboardF3: 0x3D,
        .keyboardF4: 0x3E,
        .keyboardF5: 0x3F,
        .keyboardF6: 0x40,
        .keyboardF7: 0x41,
        .keyboardF8: 0x42,
        .keyboardF9: 0x43,
        .keyboardF10: 0x44,
        .keyboardF11: 0x57,
        .keyboardF12: 0x58,

        // Modifiers
        .keyboardLeftControl: 0x1D,
        .keyboardLeftShift: 0x2A,
        .keyboardLeftAlt: 0x38,
        .keyboardLeftGUI: 0xE05B,     // Left Windows/Command
        .keyboardRightControl: 0xE01D,
        .keyboardRightShift: 0x36,
        .keyboardRightAlt: 0xE038,
        .keyboardRightGUI: 0xE05C,    // Right Windows/Command

        // Navigation (extended keys, 0xE0 prefix)
        .keyboardInsert: 0xE052,
        .keyboardDeleteForward: 0xE053,
        .keyboardHome: 0xE047,
        .keyboardEnd: 0xE04F,
        .keyboardPageUp: 0xE049,
        .keyboardPageDown: 0xE051,

        // Arrow keys
        .keyboardRightArrow: 0xE04D,
        .keyboardLeftArrow: 0xE04B,
        .keyboardDownArrow: 0xE050,
        .keyboardUpArrow: 0xE048,

        // Print/Scroll/Pause
        .keyboardPrintScreen: 0xE037,
        .keyboardScrollLock: 0x46,
        .keyboardPause: 0xE11D45,

        // Numpad
        .keypadNumLock: 0x45,
        .keypadSlash: 0xE035,
        .keypadAsterisk: 0x37,
        .keypadHyphen: 0x4A,
        .keypadPlus: 0x4E,
        .keypadEnter: 0xE01C,
        .keypad1: 0x4F,
        .keypad2: 0x50,
        .keypad3: 0x51,
        .keypad4: 0x4B,
        .keypad5: 0x4C,
        .keypad6: 0x4D,
        .keypad7: 0x47,
        .keypad8: 0x48,
        .keypad9: 0x49,
        .keypad0: 0x52,
        .keypadPeriod: 0x53,
    ]
}
