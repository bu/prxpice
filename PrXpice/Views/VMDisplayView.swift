import SwiftUI
import UIKit

/// Full-screen VM display wrapping the Metal-based display view controller.
struct VMDisplayView: View {
    let vm: VMInfo
    let spiceConfig: SpiceConfig

    @StateObject private var viewModel: VMDisplayViewModel
    @Environment(\.dismiss) private var dismiss

    init(vm: VMInfo, spiceConfig: SpiceConfig) {
        self.vm = vm
        self.spiceConfig = spiceConfig
        _viewModel = StateObject(wrappedValue: VMDisplayViewModel(vm: vm))
    }

    var body: some View {
        ZStack {
            // Metal display
            MetalDisplayViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()

            // Overlay UI
            VStack {
                // Top bar
                if viewModel.showToolbar {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                // Connection status overlay
                if viewModel.connectionState == .connecting {
                    connectingOverlay
                }

                // Input toolbar
                if viewModel.showToolbar {
                    InputToolbarView { key in
                        viewModel.handleToolbarKey(key)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Error overlay
            if let error = viewModel.error {
                errorOverlay(error)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            viewModel.connect(config: spiceConfig)
        }
        .onDisappear {
            viewModel.disconnect()
            viewModel.releaseAllModifiers()
        }
        .onTapGesture(count: 3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showToolbar.toggle()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                viewModel.disconnect()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }

            Spacer()

            Text(vm.name)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            stateIndicator
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }

    private var stateIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateColor: Color {
        switch viewModel.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnecting: return .orange
        case .disconnected: return .red
        case .error: return .red
        }
    }

    private var stateText: String {
        switch viewModel.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }

    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(vm.name)...")
                .font(.headline)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Reconnect") {
                    viewModel.connect(config: spiceConfig)
                }
                .buttonStyle(.borderedProminent)
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - UIViewControllerRepresentable

struct MetalDisplayViewRepresentable: UIViewControllerRepresentable {
    let viewModel: VMDisplayViewModel

    func makeUIViewController(context: Context) -> MetalDisplayViewController {
        let vc = MetalDisplayViewController()
        vc.delegate = context.coordinator

        // Wire renderer to display handler
        viewModel.displayHandler.renderer = vc.renderer

        return vc
    }

    func updateUIViewController(_ uiViewController: MetalDisplayViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MetalDisplayViewDelegate {
        let viewModel: VMDisplayViewModel

        init(viewModel: VMDisplayViewModel) {
            self.viewModel = viewModel
        }

        func displayView(_ vc: MetalDisplayViewController, touchBegan touch: UITouch, at point: CGPoint) {
            viewModel.touchMapper.touchBegan(at: point, timestamp: touch.timestamp)
        }

        func displayView(_ vc: MetalDisplayViewController, touchMoved touch: UITouch, at point: CGPoint) {
            viewModel.touchMapper.touchMoved(at: point, timestamp: touch.timestamp)
        }

        func displayView(_ vc: MetalDisplayViewController, touchEnded touch: UITouch, at point: CGPoint) {
            viewModel.touchMapper.touchEnded(at: point, timestamp: touch.timestamp)
        }

        func displayView(_ vc: MetalDisplayViewController, touchCancelled touch: UITouch, at point: CGPoint) {
            viewModel.touchMapper.touchCancelled()
        }

        func displayViewSize(_ vc: MetalDisplayViewController) -> CGSize {
            vc.view.bounds.size
        }
    }
}
