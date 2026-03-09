import SwiftUI
import UIKit

/// On-screen keyboard shown as `SoftKeyboardField.inputView`.
/// Because `inputView` is non-nil, iOS presents it even when a hardware keyboard is connected.
struct VMSoftKeyboard: View {
    let onKey: (String) -> Void
    @State private var shifted = false
    @State private var caps    = false

    private var shift: Bool { shifted || caps }

    private let digits = ["1","2","3","4","5","6","7","8","9","0"]
    private let row1   = ["q","w","e","r","t","y","u","i","o","p"]
    private let row2   = ["a","s","d","f","g","h","j","k","l"]
    private let row3   = ["z","x","c","v","b","n","m"]

    var body: some View {
        VStack(spacing: 6) {
            // Number row + Backspace
            HStack(spacing: 4) {
                ForEach(digits, id: \.self) { charKey($0) }
                specialKey("⌫", "\u{08}", flex: false)
            }

            // QWERTY
            HStack(spacing: 4) {
                ForEach(row1, id: \.self) { charKey($0) }
            }

            // ASDF
            HStack(spacing: 4) {
                ForEach(row2, id: \.self) { charKey($0) }
            }

            // Shift + ZXCV + Shift
            HStack(spacing: 4) {
                shiftButton
                ForEach(row3, id: \.self) { charKey($0) }
                shiftButton
            }

            // Bottom row
            HStack(spacing: 4) {
                specialKey("Esc", "\u{1B}", flex: false)
                specialKey("Tab", "\t",     flex: false)
                specialKey("Space", " ",    flex: true)
                specialKey("↵",   "\r",    flex: false)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemGray5))
    }

    // MARK: - Helpers

    private func send(_ value: String) {
        onKey(value)
        if shifted { shifted = false }
    }

    @ViewBuilder
    private func charKey(_ k: String) -> some View {
        let label = shift ? k.uppercased() : k
        Button { send(label) } label: {
            Text(label)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Color(UIColor.systemGray3))
                .foregroundStyle(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func specialKey(_ label: String, _ value: String, flex: Bool) -> some View {
        Button { send(value) } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: flex ? .infinity : nil)
                .padding(.horizontal, flex ? 0 : 10)
                .frame(height: 40)
                .background(Color(UIColor.systemGray4))
                .foregroundStyle(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var shiftButton: some View {
        Button {
            if caps         { caps = false; shifted = false }
            else if shifted { caps = true;  shifted = false }
            else            { shifted = true }
        } label: {
            Image(systemName: caps ? "capslock.fill" : (shifted ? "shift.fill" : "shift"))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 40)
                .background(Color(UIColor.systemGray4))
                .foregroundStyle(caps ? Color.yellow : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
