import SwiftUI

/// On-screen toolbar for modifier keys and special key combos.
/// Displayed as a floating bar over the VM display.
struct InputToolbarView: View {
    let onKey: (InputToolbarKey) -> Void
    @State private var showFKeys = false
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false

    var body: some View {
        VStack(spacing: 4) {
            if showFKeys {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(1...12, id: \.self) { num in
                            toolbarButton("F\(num)") {
                                onKey(.functionKey(num))
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 36)
            }

            HStack(spacing: 6) {
                modifierButton("Ctrl", isActive: $ctrlActive) {
                    onKey(.modifier(.ctrl))
                }
                modifierButton("Alt", isActive: $altActive) {
                    onKey(.modifier(.alt))
                }
                modifierButton("Shift", isActive: $shiftActive) {
                    onKey(.modifier(.shift))
                }

                Divider().frame(height: 24)

                toolbarButton("Esc") { onKey(.escape) }
                toolbarButton("Tab") { onKey(.tab) }
                toolbarButton("F-Keys") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFKeys.toggle()
                    }
                }

                Divider().frame(height: 24)

                toolbarButton("C-A-D") { onKey(.ctrlAltDel) }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func toolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func modifierButton(_ title: String, isActive: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button {
            isActive.wrappedValue.toggle()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    isActive.wrappedValue
                        ? Color.accentColor.opacity(0.4)
                        : Color.secondary.opacity(0.2),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }
}

enum InputToolbarKey {
    case escape
    case tab
    case ctrlAltDel
    case functionKey(Int)
    case modifier(Modifier)

    enum Modifier {
        case ctrl, alt, shift
    }
}
