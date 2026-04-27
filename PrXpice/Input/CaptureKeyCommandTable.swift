import UIKit

/// Generates the `UIKeyCommand` list registered while capture mode is active
/// on Mac Catalyst, and provides the inverse lookup from `UIKeyCommand.input`
/// to a PC XT scancode for replay through `KeyboardManager.sendKeyCommandTap`.
///
/// `UIKeyCommand` only exposes a String input + modifier flags (no HID usage,
/// no keyDown / keyUp). Hence a dedicated table independent of `ScancodeMap`.
enum CaptureKeyCommandTable {

    // MARK: - Modifier scancodes (PC XT, AT set 1)
    static let scancodeLeftCtrl: UInt32  = 0x1D
    static let scancodeLeftShift: UInt32 = 0x2A
    static let scancodeLeftAlt: UInt32   = 0x38
    static let scancodeLeftGUI: UInt32   = 0xE05B   // Cmd on Mac

    /// Returns the modifier scancodes that should be pressed for these flags,
    /// in press order (release order is the reverse).
    static func modifierScancodes(for flags: UIKeyCommand.ModifierFlags) -> [UInt32] {
        var out: [UInt32] = []
        // Ordering matches a typical OS keystroke: Ctrl, Shift, Alt, Cmd.
        if flags.contains(.control)   { out.append(scancodeLeftCtrl) }
        if flags.contains(.shift)     { out.append(scancodeLeftShift) }
        if flags.contains(.alternate) { out.append(scancodeLeftAlt) }
        if flags.contains(.command)   { out.append(scancodeLeftGUI) }
        return out
    }

    /// Maps a `UIKeyCommand.input` string to its base XT scancode (no shift logic;
    /// shift is conveyed via `modifierFlags`).
    static func baseScancode(forInput input: String) -> UInt32? {
        return inputToScancode[input]
    }

    // MARK: - Command list factory

    /// Build the set of `UIKeyCommand`s to register while capture mode is
    /// active. `excludedCombos` lets the caller drop combos that collide with
    /// the user's VM-switch hotkey (e.g. Ctrl+Left/Right).
    static func makeCommands(
        action: Selector,
        excludedCombos: Set<Combo> = []
    ) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        commands.reserveCapacity(combos.count)
        for combo in combos where !excludedCombos.contains(combo) {
            let cmd = UIKeyCommand(input: combo.input,
                                   modifierFlags: combo.flags,
                                   action: action)
            cmd.wantsPriorityOverSystemBehavior = true
            commands.append(cmd)
        }
        return commands
    }

    /// Hashable representation of an (input, flags) pair used to dedupe and
    /// to express exclusions.
    struct Combo: Hashable {
        let input: String
        let flags: UIKeyCommand.ModifierFlags

        static func == (lhs: Combo, rhs: Combo) -> Bool {
            lhs.input == rhs.input && lhs.flags == rhs.flags
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(input)
            hasher.combine(flags.rawValue)
        }
    }

    // MARK: - Combo enumeration

    private static let functionKeyInputs: [String] = [
        UIKeyCommand.inputF1,  UIKeyCommand.inputF2,  UIKeyCommand.inputF3,
        UIKeyCommand.inputF4,  UIKeyCommand.inputF5,  UIKeyCommand.inputF6,
        UIKeyCommand.inputF7,  UIKeyCommand.inputF8,  UIKeyCommand.inputF9,
        UIKeyCommand.inputF10, UIKeyCommand.inputF11, UIKeyCommand.inputF12,
    ]

    private static let navigationInputs: [String] = [
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow,
        UIKeyCommand.inputHome,
        UIKeyCommand.inputEnd,
        UIKeyCommand.inputPageUp,
        UIKeyCommand.inputPageDown,
    ]

    /// All (input, flags) pairs we want to intercept while capture mode is on.
    /// Generated lazily on first access; ~250 combos.
    private static let combos: [Combo] = {
        var out: [Combo] = []

        // Letters a-z with several common modifier sets.
        let letters = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        let letterModSets: [UIKeyCommand.ModifierFlags] = [
            .command,
            [.command, .shift],
            [.command, .alternate],
            [.command, .control],
        ]
        for letter in letters {
            for mods in letterModSets {
                out.append(Combo(input: letter, flags: mods))
            }
        }

        // Digits 0-9 with Cmd and Cmd+Shift.
        let digits = "0123456789".map { String($0) }
        let digitModSets: [UIKeyCommand.ModifierFlags] = [.command, [.command, .shift]]
        for digit in digits {
            for mods in digitModSets {
                out.append(Combo(input: digit, flags: mods))
            }
        }

        // F1-F12 with Cmd.
        for fkey in functionKeyInputs {
            out.append(Combo(input: fkey, flags: .command))
        }

        // Punctuation with Cmd.
        let punctuation = ["`", ",", ".", "/", "[", "]", "\\", ";", "'", "-", "="]
        for p in punctuation {
            out.append(Combo(input: p, flags: .command))
        }

        // Whitespace and Esc with Cmd.
        out.append(Combo(input: "\t", flags: .command))
        out.append(Combo(input: " ",  flags: .command))
        out.append(Combo(input: UIKeyCommand.inputEscape, flags: .command))

        // Navigation cluster with Cmd.
        for nav in navigationInputs {
            out.append(Combo(input: nav, flags: .command))
        }

        return out
    }()

    // MARK: - Input string → XT scancode

    private static let inputToScancode: [String: UInt32] = {
        var m: [String: UInt32] = [
            // Letters: same XT base as ScancodeMap; shift conveyed via flags.
            "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12, "f": 0x21,
            "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24, "k": 0x25, "l": 0x26,
            "m": 0x32, "n": 0x31, "o": 0x18, "p": 0x19, "q": 0x10, "r": 0x13,
            "s": 0x1F, "t": 0x14, "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D,
            "y": 0x15, "z": 0x2C,

            // Digits 1-9 then 0.
            "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
            "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,

            // Punctuation.
            "-": 0x0C, "=": 0x0D, "[": 0x1A, "]": 0x1B, "\\": 0x2B,
            ";": 0x27, "'": 0x28, "`": 0x29, ",": 0x33, ".": 0x34, "/": 0x35,

            // Whitespace and control.
            "\t": 0x0F,
            " ":  0x39,
            "\r": 0x1C,
            "\n": 0x1C,
        ]
        // F1-F12 (private-use codepoints from UIKit).
        let fScancodes: [UInt32] = [
            0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40,
            0x41, 0x42, 0x43, 0x44, 0x57, 0x58,
        ]
        for (input, code) in zip(functionKeyInputs, fScancodes) {
            m[input] = code
        }

        // Escape and navigation cluster (extended scancodes use 0xE0xx).
        m[UIKeyCommand.inputEscape]     = 0x01
        m[UIKeyCommand.inputUpArrow]    = 0xE048
        m[UIKeyCommand.inputDownArrow]  = 0xE050
        m[UIKeyCommand.inputLeftArrow]  = 0xE04B
        m[UIKeyCommand.inputRightArrow] = 0xE04D
        m[UIKeyCommand.inputHome]       = 0xE047
        m[UIKeyCommand.inputEnd]        = 0xE04F
        m[UIKeyCommand.inputPageUp]     = 0xE049
        m[UIKeyCommand.inputPageDown]   = 0xE051
        return m
    }()
}
