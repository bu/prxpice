import SwiftUI
import UIKit

/// Full-screen VM display wrapping the Metal-based display view controller.
struct VMDisplayView: View {
    let session: VMSession
    let isActive: Bool
    let onClose: () -> Void
    let onBackToList: () -> Void
    let onFourFingerSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    @ObservedObject private var viewModel: VMDisplayViewModel
    @State private var logPaused = false
    @State private var frozenLog: [String] = []
    @State private var showDebugPanel = false
    @State private var debugPanelPosition: CGPoint = .zero
    @State private var controlButtonPosition: CGPoint = .zero
    @State private var showControlMenu = false
    @State private var showResolutionPicker = false

    init(session: VMSession,
         isActive: Bool = true,
         onClose: @escaping () -> Void,
         onBackToList: @escaping () -> Void = {},
         onFourFingerSwipe: @escaping (UISwipeGestureRecognizer.Direction) -> Void = { _ in }) {
        self.session = session
        self.isActive = isActive
        self.onClose = onClose
        self.onBackToList = onBackToList
        self.onFourFingerSwipe = onFourFingerSwipe
        _viewModel = ObservedObject(wrappedValue: session.viewModel)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // VM display: 16:10 aspect ratio, respects safe area top/bottom
                MetalDisplayViewRepresentable(viewModel: viewModel, isActive: isActive, onFourFingerSwipe: onFourFingerSwipe)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Floating debug log panel
                if showDebugPanel {
                    debugLogView
                        .frame(width: 640, height: 400)
                        .position(debugPanelPosition)
                        .gesture(
                            DragGesture()
                                .onChanged { v in debugPanelPosition = v.location }
                        )
                }

                // Floating control button (draggable, snaps to edge)
                floatingControlButton(in: geo)
            }
            .onAppear {
                if controlButtonPosition == .zero {
                    controlButtonPosition = CGPoint(x: geo.size.width - 22, y: geo.size.height / 2)
                }
                if debugPanelPosition == .zero {
                    debugPanelPosition = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                // Connect after the view is in the hierarchy and the renderer is wired.
                session.connect()
            }
        }
        .ignoresSafeArea(edges: .all)
        .confirmationDialog("Display Resolution (16:10)", isPresented: $showResolutionPicker) {
            ForEach(VMResolution.presets16x10) { res in
                Button(res.label) {
                    viewModel.setResolution(res)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func floatingControlButton(in geo: GeometryProxy) -> some View {
        // Left/right edge → vertical pill; top/bottom edge → horizontal pill
        let isVertical = controlButtonPosition.x < 44 || controlButtonPosition.x > geo.size.width - 44

        return ZStack(alignment: .topLeading) {
            pillView(isVertical: isVertical)
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
                .opacity(showControlMenu ? 1.0 : 0.55)
                .scaleEffect(showControlMenu ? 1.0 : 0.92)
                .position(controlButtonPosition)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            showControlMenu = false
                            controlButtonPosition = v.location
                        }
                        .onEnded { v in
                            let pos = v.location
                            let m = 22.0
                            let dLeft   = pos.x
                            let dRight  = geo.size.width - pos.x
                            let dTop    = pos.y
                            let dBottom = geo.size.height - pos.y
                            let nearest = min(dLeft, dRight, dTop, dBottom)
                            let snapPoint: CGPoint
                            if nearest == dLeft {
                                snapPoint = CGPoint(x: m, y: max(m * 2, min(pos.y, geo.size.height - m * 2)))
                            } else if nearest == dRight {
                                snapPoint = CGPoint(x: geo.size.width - m, y: max(m * 2, min(pos.y, geo.size.height - m * 2)))
                            } else if nearest == dTop {
                                snapPoint = CGPoint(x: max(m * 2, min(pos.x, geo.size.width - m * 2)), y: m)
                            } else {
                                snapPoint = CGPoint(x: max(m * 2, min(pos.x, geo.size.width - m * 2)), y: geo.size.height - m)
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                                controlButtonPosition = snapPoint
                            }
                        }
                )
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func pillView(isVertical: Bool) -> some View {
        let gearBtn = Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                showControlMenu.toggle()
            }
        }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(showControlMenu ? 45 : 0))
                .animation(.spring(response: 0.28, dampingFraction: 0.75), value: showControlMenu)
                .frame(width: 44, height: 44)
        }

        // 2 items above gear, 2 below — gear stays visually centered.
        // Above: eye (debug), display (resolution)   Below: list (back to list), xmark (close)
        if isVertical {
            VStack(spacing: 0) {
                if showControlMenu {
                    Button(action: { showDebugPanel.toggle() }) {
                        Image(systemName: showDebugPanel ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 28, height: 0.5)
                    Button(action: { showResolutionPicker = true }) {
                        Image(systemName: "display")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 28, height: 0.5)
                }
                gearBtn
                if showControlMenu {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 28, height: 0.5)
                    Button(action: { onBackToList() }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 28, height: 0.5)
                    Button(action: { onClose() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                            .frame(width: 44, height: 44)
                    }
                }
            }
        } else {
            HStack(spacing: 0) {
                if showControlMenu {
                    Button(action: { showDebugPanel.toggle() }) {
                        Image(systemName: showDebugPanel ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.5, height: 28)
                    Button(action: { showResolutionPicker = true }) {
                        Image(systemName: "display")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.5, height: 28)
                }
                gearBtn
                if showControlMenu {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.5, height: 28)
                    Button(action: { onBackToList() }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.5, height: 28)
                    Button(action: { onClose() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                            .frame(width: 44, height: 44)
                    }
                }
            }
        }
    }

    private var debugLogView: some View {
        let entries = logPaused ? frozenLog : viewModel.debugLog

        return ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 36)   // leave room for overlay buttons
                    .padding(.bottom, 4)
                }
                .onChange(of: entries.count) { _ in
                    if !logPaused, let last = entries.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            // Floating action buttons — top-right corner
            HStack(spacing: 5) {
                Button {
                    let all = entries.joined(separator: "\n")
                    UIPasteboard.general.string = all
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.cyan.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                Button {
                    if logPaused {
                        logPaused = false
                    } else {
                        frozenLog = viewModel.debugLog
                        logPaused = true
                    }
                } label: {
                    Image(systemName: logPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(logPaused ? Color.green.opacity(0.75) : Color.orange.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(6)
        }
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - UIViewControllerRepresentable

struct MetalDisplayViewRepresentable: UIViewControllerRepresentable {
    let viewModel: VMDisplayViewModel
    let isActive: Bool
    let onFourFingerSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    init(viewModel: VMDisplayViewModel,
         isActive: Bool = true,
         onFourFingerSwipe: @escaping (UISwipeGestureRecognizer.Direction) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.isActive = isActive
        self.onFourFingerSwipe = onFourFingerSwipe
    }

    func makeUIViewController(context: Context) -> MetalDisplayViewController {
        let vc = MetalDisplayViewController()
        vc.delegate = context.coordinator
        // Wire renderer immediately when viewDidLoad creates it.
        // Accessing vc.view here also triggers viewDidLoad synchronously.
        let displayHandler = viewModel.displayHandler
        vc.onRendererReady = { renderer in
            displayHandler.renderer = renderer
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MetalDisplayViewController, context: Context) {
        // Do NOT hide via isHidden — CAMetalLayer can lose state when the view is hidden/shown.
        // Visibility is handled by zIndex/allowsHitTesting in the SwiftUI layer instead.
        if isActive {
            uiViewController.makeActive()
        }
        // Belt-and-suspenders: sync renderer in case it changed.
        if let renderer = uiViewController.renderer {
            viewModel.displayHandler.renderer = renderer
        }
        context.coordinator.onFourFingerSwipe = onFourFingerSwipe
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MetalDisplayViewDelegate {
        let viewModel: VMDisplayViewModel
        var onFourFingerSwipe: (UISwipeGestureRecognizer.Direction) -> Void = { _ in }
        private var mouseEventLogged = false

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

        func displayView(_ vc: MetalDisplayViewController, pointerMovedTo point: CGPoint) {
            if !mouseEventLogged {
                mouseEventLogged = true
                DispatchQueue.main.async {
                    self.viewModel.appendDebug("mouse first hover at \(Int(point.x)),\(Int(point.y))")
                }
            }
            viewModel.inputHandler.mouseMove(x: Int(point.x), y: Int(point.y))
        }

        func displayView(_ vc: MetalDisplayViewController, keyDown key: UIKey) {
            viewModel.keyboardManager.handleKeyDown(key)
        }

        func displayView(_ vc: MetalDisplayViewController, keyUp key: UIKey) {
            viewModel.keyboardManager.handleKeyUp(key)
        }

        func displayViewSize(_ vc: MetalDisplayViewController) -> CGSize {
            vc.view.bounds.size
        }

        func displayViewDidFourFingerSwipe(_ vc: MetalDisplayViewController, direction: UISwipeGestureRecognizer.Direction) {
            onFourFingerSwipe(direction)
        }
    }
}
