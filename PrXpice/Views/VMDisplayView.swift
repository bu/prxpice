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
    @State private var useRelativeMouse = false
    @State private var showKeyboard = false
    @State private var isKeyboardVisible = false

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
                MetalDisplayViewRepresentable(
                    viewModel: viewModel,
                    isActive: isActive,
                    onFourFingerSwipe: onFourFingerSwipe,
                    showKeyboard: showKeyboard
                )
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

                // Keyboard toggle — fixed bottom right corner
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: { showKeyboard.toggle() }) {
                            Image(systemName: isKeyboardVisible ? "keyboard.chevron.compact.down.fill" : "keyboard")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 36)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        }
                        .padding(.trailing, 3)
                        .padding(.bottom, 3)
                    }
                }
                .zIndex(8)
                .allowsHitTesting(true)

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
            .onChange(of: geo.size) { newSize in
                // Re-snap pill to the nearest edge center after orientation change
                let m = 22.0
                let pos = controlButtonPosition
                let dLeft   = pos.x
                let dRight  = newSize.width - pos.x
                let dTop    = pos.y
                let dBottom = newSize.height - pos.y
                let nearest = min(dLeft, dRight, dTop, dBottom)
                let snapped: CGPoint
                if nearest == dLeft {
                    snapped = CGPoint(x: m, y: newSize.height / 2)
                } else if nearest == dRight {
                    snapped = CGPoint(x: newSize.width - m, y: newSize.height / 2)
                } else if nearest == dTop {
                    snapped = CGPoint(x: newSize.width / 2, y: m)
                } else {
                    snapped = CGPoint(x: newSize.width / 2, y: newSize.height - m)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    controlButtonPosition = snapped
                }
            }
        }
        .ignoresSafeArea(edges: .all)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
            showKeyboard = false
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
                    Button(action: {
                        useRelativeMouse.toggle()
                        viewModel.inputHandler.useRelativeMouse = useRelativeMouse
                    }) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(useRelativeMouse ? Color.yellow : .white.opacity(0.9))
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
                    Button(action: {
                        useRelativeMouse.toggle()
                        viewModel.inputHandler.useRelativeMouse = useRelativeMouse
                    }) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(useRelativeMouse ? Color.yellow : .white.opacity(0.9))
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
                    .padding(.top, 36)
                    .padding(.bottom, 4)
                }
                .onChange(of: entries.count) { _ in
                    if !logPaused, let last = entries.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

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
    let showKeyboard: Bool

    init(viewModel: VMDisplayViewModel,
         isActive: Bool = true,
         onFourFingerSwipe: @escaping (UISwipeGestureRecognizer.Direction) -> Void = { _ in },
         showKeyboard: Bool = false) {
        self.viewModel = viewModel
        self.isActive = isActive
        self.onFourFingerSwipe = onFourFingerSwipe
        self.showKeyboard = showKeyboard
    }

    func makeUIViewController(context: Context) -> MetalDisplayViewController {
        let vc = MetalDisplayViewController()
        vc.delegate = context.coordinator
        let displayHandler = viewModel.displayHandler
        vc.onRendererReady = { renderer in
            displayHandler.renderer = renderer
        }
        context.coordinator.vc = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: MetalDisplayViewController, context: Context) {
        if isActive {
            uiViewController.makeActive()
        }
        if let renderer = uiViewController.renderer {
            viewModel.displayHandler.renderer = renderer
        }
        context.coordinator.onFourFingerSwipe = onFourFingerSwipe

        // Show/hide soft keyboard when the toggle changes
        if showKeyboard != context.coordinator.lastShowKeyboard {
            context.coordinator.lastShowKeyboard = showKeyboard
            if showKeyboard {
                uiViewController.showSoftKeyboard()
            } else {
                uiViewController.hideSoftKeyboard()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MetalDisplayViewDelegate {
        let viewModel: VMDisplayViewModel
        var onFourFingerSwipe: (UISwipeGestureRecognizer.Direction) -> Void = { _ in }
        var lastShowKeyboard = false
        weak var vc: MetalDisplayViewController?

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

        func displayView(_ vc: MetalDisplayViewController, didInsertText text: String) {
            viewModel.keyboardManager.handleText(text)
        }

        func displayViewScrollUp(_ vc: MetalDisplayViewController) {
            viewModel.inputHandler.scrollUp()
        }

        func displayViewScrollDown(_ vc: MetalDisplayViewController) {
            viewModel.inputHandler.scrollDown()
        }

        func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryTapped scancode: UInt32) {
            viewModel.inputHandler.keyPress(scancode: scancode)
            viewModel.inputHandler.keyRelease(scancode: scancode)
        }

        func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryModifierDown scancode: UInt32) {
            viewModel.inputHandler.keyPress(scancode: scancode)
        }

        func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryModifierUp scancode: UInt32) {
            viewModel.inputHandler.keyRelease(scancode: scancode)
        }
    }
}
