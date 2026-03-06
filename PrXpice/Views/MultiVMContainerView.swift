import SwiftUI
import UIKit

/// Container that manages multiple simultaneous VM sessions.
/// Shows one session at a time; 4-finger swipe left/right switches between sessions.
/// All session views are kept alive (via opacity) to prevent Metal renderer teardown on switch.
@MainActor
struct MultiVMContainerView: View {
    @Binding var sessions: [VMSession]
    @State private var currentIndex: Int = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
                Color.black.ignoresSafeArea()

                // All session views stay alive — prevents Metal renderer teardown when switching.
                // Visibility is controlled via UIKit view.isHidden (passed through isActive),
                // which does NOT trigger viewWillDisappear unlike SwiftUI opacity.
                ForEach(sessions) { session in
                    let idx = sessions.firstIndex(where: { $0.id == session.id }) ?? 0
                    VMDisplayView(
                        session: session,
                        isActive: idx == currentIndex,
                        onClose: { closeSession(session: session) },
                        onBackToList: { dismiss() },
                        onFourFingerSwipe: handleSwipe
                    )
                    .zIndex(idx == currentIndex ? 1 : 0)
                    .allowsHitTesting(idx == currentIndex)
                }

                // Empty state — shown instead of auto-dismissing to avoid animation race
                if sessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "desktopcomputer.slash")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No Active Connections")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Button("Back to VM List") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                // Session indicator — pinned to top center
                if !sessions.isEmpty {
                    VStack {
                        sessionIndicator
                            .padding(.top, 8)
                        Spacer()
                    }
                    .zIndex(10)
                    .allowsHitTesting(true)
                }
        }
        .ignoresSafeArea(edges: .all)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: sessions.count) { oldCount, newCount in
            if newCount > oldCount {
                // New session added — switch to it
                currentIndex = newCount - 1
            } else if newCount > 0 && currentIndex >= newCount {
                currentIndex = newCount - 1
            }
            // newCount == 0: show empty state (no auto-dismiss to avoid animation race)
        }
    }

    private var sessionIndicator: some View {
        HStack(spacing: 6) {
            ForEach(sessions.indices, id: \.self) { i in
                if i == currentIndex {
                    // Active VM — inner pill with name
                    Text(sessions[i].vm.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white, in: Capsule())
                } else {
                    // Inactive VM — dot button to switch
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentIndex = i
                        }
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4)
    }

    private func handleSwipe(_ direction: UISwipeGestureRecognizer.Direction) {
        guard sessions.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            if direction == .left {
                currentIndex = (currentIndex + 1) % sessions.count
            } else if direction == .right {
                currentIndex = (currentIndex - 1 + sessions.count) % sessions.count
            }
        }
    }

    private func closeSession(session: VMSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.disconnect()
        sessions.remove(at: index)
        // Don't call dismiss() here — onChange handles index adjustment.
        // When sessions is empty, the empty state view is shown; user navigates back explicitly.
        guard !sessions.isEmpty else { return }
        if currentIndex >= sessions.count {
            currentIndex = sessions.count - 1
        } else if index < currentIndex {
            currentIndex -= 1
        }
    }
}
