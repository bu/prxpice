import UIKit
import Metal
import QuartzCore

/// UIViewController that hosts a CAMetalLayer for rendering the SPICE VM display.
/// Uses CADisplayLink for vsync-aligned rendering with coalesced updates.
///
/// This is the performance-critical display component. Touch events are forwarded
/// to a delegate for mouse input translation.
protocol MetalDisplayViewDelegate: AnyObject {
    func displayView(_ vc: MetalDisplayViewController, touchBegan touch: UITouch, at point: CGPoint)
    func displayView(_ vc: MetalDisplayViewController, touchMoved touch: UITouch, at point: CGPoint)
    func displayView(_ vc: MetalDisplayViewController, touchEnded touch: UITouch, at point: CGPoint)
    func displayView(_ vc: MetalDisplayViewController, touchCancelled touch: UITouch, at point: CGPoint)
    func displayView(_ vc: MetalDisplayViewController, pointerMovedTo point: CGPoint)
    func displayView(_ vc: MetalDisplayViewController, keyDown key: UIKey)
    func displayView(_ vc: MetalDisplayViewController, keyUp key: UIKey)
    func displayViewSize(_ vc: MetalDisplayViewController) -> CGSize
    func displayViewDidFourFingerSwipe(_ vc: MetalDisplayViewController, direction: UISwipeGestureRecognizer.Direction)
    func displayView(_ vc: MetalDisplayViewController, didInsertText text: String)
    func displayViewScrollUp(_ vc: MetalDisplayViewController)
    func displayViewScrollDown(_ vc: MetalDisplayViewController)
    func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryTapped scancode: UInt32)
    func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryModifierDown scancode: UInt32)
    func displayView(_ vc: MetalDisplayViewController, keyboardAccessoryModifierUp scancode: UInt32)
}

/// Weak proxy breaks the CADisplayLink → target strong-reference cycle,
/// allowing MetalDisplayViewController to be deallocated normally.
private final class DisplayLinkProxy: NSObject {
    weak var target: MetalDisplayViewController?
    @objc func tick() { target?.renderFrame() }
}

final class MetalDisplayViewController: UIViewController {
    private(set) var renderer: MetalRenderer?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var metalLayer: CAMetalLayer!
    private lazy var keyboardField: SoftKeyboardField = {
        let f = SoftKeyboardField()
        f.onInsertText = { [weak self] text in
            guard let self else { return }
            self.delegate?.displayView(self, didInsertText: text)
        }
        f.onScancode = { [weak self] sc in
            guard let self else { return }
            self.delegate?.displayView(self, keyboardAccessoryTapped: sc)
        }
        f.onModifierDown = { [weak self] sc in
            guard let self else { return }
            self.delegate?.displayView(self, keyboardAccessoryModifierDown: sc)
        }
        f.onModifierUp = { [weak self] sc in
            guard let self else { return }
            self.delegate?.displayView(self, keyboardAccessoryModifierUp: sc)
        }
        f.parentVC = self
        f.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
        return f
    }()

    weak var delegate: MetalDisplayViewDelegate?
    var onRendererReady: ((MetalRenderer) -> Void)?

    // Display scaling — independent per-axis to match stretch-to-fill GPU rendering
    private var displayScaleX: CGFloat = 1.0
    private var displayScaleY: CGFloat = 1.0
    private var displayOffset: CGPoint = .zero

    // Zoom/pan state
    private(set) var zoomScale: CGFloat = 1.0
    private(set) var panOffset: CGPoint = .zero
    private var minZoom: CGFloat = 1.0
    private var maxZoom: CGFloat = 4.0

    // Center zoom indicator circle with 4 directional arrows
    private let zoomIndicator = ZoomIndicatorView()

    override var canBecomeFirstResponder: Bool { true }

    override func loadView() {
        let metalView = UIView(frame: .zero)
        metalView.backgroundColor = .black
        self.view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.rendering.error("Metal is not supported on this device")
            return
        }

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true  // SPICE xRGB surfaces have alpha=0; treat layer as opaque
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.presentsWithTransaction = false
        view.layer.addSublayer(metalLayer)

        renderer = MetalRenderer(device: device)
        onRendererReady?(renderer!)

        setupGestureRecognizers()
        startDisplayLink()

        // Zoom indicator
        zoomIndicator.onTap = { [weak self] in self?.resetZoom() }
        zoomIndicator.translatesAutoresizingMaskIntoConstraints = false
        zoomIndicator.alpha = 0
        zoomIndicator.isUserInteractionEnabled = false
        view.addSubview(zoomIndicator)
        NSLayoutConstraint.activate([
            zoomIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoomIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            zoomIndicator.widthAnchor.constraint(equalToConstant: 52),
            zoomIndicator.heightAnchor.constraint(equalToConstant: 52),
        ])

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        metalLayer.frame = view.bounds
        metalLayer.drawableSize = CGSize(
            width: view.bounds.width * UIScreen.main.scale,
            height: view.bounds.height * UIScreen.main.scale
        )
        updateDisplayTransform()
    }

    deinit {
        stopDisplayLink()
    }

    // viewWillDisappear is intentionally NOT stopping the display link.
    // In a multi-VM ZStack, SwiftUI calls viewWillDisappear on sibling VCs when
    // opacity changes — stopping the link here would black out other VMs.
    // The link runs until the VC is actually deallocated (deinit above).

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
        becomeFirstResponder()
    }

    /// Called by the representable when a session becomes the active (visible) one.
    func makeActive() {
        startDisplayLink()
        becomeFirstResponder()
    }

    func showSoftKeyboard() {
        if keyboardField.superview == nil { view.addSubview(keyboardField) }
        keyboardField.becomeFirstResponder()
    }

    func hideSoftKeyboard() {
        keyboardField.resignFirstResponder()
        becomeFirstResponder()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.target = self
        displayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // Allow up to 120 fps on ProMotion displays; floor at 30 for battery.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    fileprivate func renderFrame() {
        updateDisplayTransform()

        guard let renderer = renderer,
              let drawable = metalLayer.nextDrawable()
        else { return }

        let viewSize = view.bounds.size
        if viewSize.width > 0 && viewSize.height > 0 {
            renderer.zoomScale = Float(zoomScale)
            renderer.panNormalized = SIMD2<Float>(
                Float(panOffset.x / viewSize.width),
                Float(panOffset.y / viewSize.height)
            )
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        renderer.draw(in: drawable, renderPassDescriptor: passDescriptor)
    }

    // MARK: - Coordinate Transform

    /// Updates the transform from view coordinates to VM display coordinates.
    /// Uses independent per-axis scaling to match the stretch-to-fill GPU rendering.
    private func updateDisplayTransform() {
        guard let renderer = renderer,
              renderer.displayWidth > 0, renderer.displayHeight > 0
        else { return }

        let viewSize = view.bounds.size

        // GPU renders the VM texture stretched to fill the full view (no letterboxing),
        // so coordinate mapping must use the same per-axis scale, not min(scaleX, scaleY).
        displayScaleX = (viewSize.width  / CGFloat(renderer.displayWidth))  * zoomScale
        displayScaleY = (viewSize.height / CGFloat(renderer.displayHeight)) * zoomScale
        // Zoom is centered on the view center; offset accounts for that so touch
        // coordinates map correctly: vmX = (touchX - displayOffset.x) / displayScaleX
        displayOffset = CGPoint(
            x: viewSize.width  / 2 * (1 - zoomScale) + panOffset.x,
            y: viewSize.height / 2 * (1 - zoomScale) + panOffset.y
        )
    }

    /// Converts a view-space point to VM display coordinates.
    func viewPointToDisplayPoint(_ viewPoint: CGPoint) -> CGPoint? {
        guard displayScaleX > 0, displayScaleY > 0 else { return nil }

        let x = (viewPoint.x - displayOffset.x) / displayScaleX
        let y = (viewPoint.y - displayOffset.y) / displayScaleY

        guard let renderer = renderer,
              x >= 0, x < CGFloat(renderer.displayWidth),
              y >= 0, y < CGFloat(renderer.displayHeight)
        else { return nil }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Gesture Recognizers

    private func setupGestureRecognizers() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(doubleTap)

        // Mouse pointer movement (no button held)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        view.addGestureRecognizer(hover)

        // Bluetooth mouse / trackpad scroll wheel
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.allowedScrollTypesMask = [.discrete, .continuous]
        scroll.maximumNumberOfTouches = 0  // scroll events only, no finger touches
        view.addGestureRecognizer(scroll)

        // 4-finger swipe to switch between VM sessions
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleFourFingerSwipe(_:)))
            swipe.numberOfTouchesRequired = 4
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }

        view.isMultipleTouchEnabled = true
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let point = gesture.location(in: view)
        if let displayPoint = viewPointToDisplayPoint(point) {
            delegate?.displayView(self, pointerMovedTo: displayPoint)
        }
    }

    private var scrollAccumY: CGFloat = 0
    private let scrollThreshold: CGFloat = 10

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { scrollAccumY = 0 }
        let delta = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        scrollAccumY += delta.y
        while scrollAccumY <= -scrollThreshold {
            delegate?.displayViewScrollUp(self)
            scrollAccumY += scrollThreshold
        }
        while scrollAccumY >= scrollThreshold {
            delegate?.displayViewScrollDown(self)
            scrollAccumY -= scrollThreshold
        }
    }

    /// Clamps panOffset so the VM display never scrolls beyond its own boundary.
    /// Max pan = viewSize/2 * (zoom-1), which keeps UV coords in [0,1].
    private func clampPanOffset() {
        let viewSize = view.bounds.size
        let maxX = viewSize.width  * 0.5 * (zoomScale - 1)
        let maxY = viewSize.height * 0.5 * (zoomScale - 1)
        panOffset.x = max(-maxX, min(maxX, panOffset.x))
        panOffset.y = max(-maxY, min(maxY, panOffset.y))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let r = gesture.scale
            let center = gesture.location(in: view)
            let newZoom = min(max(zoomScale * r, minZoom), maxZoom)
            let actualR = newZoom / zoomScale
            // Keep the point under the pinch center fixed in UV space
            panOffset.x = (1 - actualR) * (center.x - view.bounds.width  / 2) + actualR * panOffset.x
            panOffset.y = (1 - actualR) * (center.y - view.bounds.height / 2) + actualR * panOffset.y
            zoomScale = newZoom
            gesture.scale = 1.0
            clampPanOffset()
            updateDisplayTransform()
            updateZoomOverlay()
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: view)
            panOffset.x += translation.x
            panOffset.y += translation.y
            gesture.setTranslation(.zero, in: view)
            clampPanOffset()
            updateDisplayTransform()
            updateZoomOverlay()
        default:
            break
        }
    }

    @objc private func handleFourFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        delegate?.displayViewDidFourFingerSwipe(self, direction: gesture.direction)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        resetZoom()
    }

    @objc private func handleResetZoom() {
        resetZoom()
    }

    private func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
        updateDisplayTransform()
        updateZoomOverlay()
    }

    private func updateZoomOverlay() {
        let isZoomed = zoomScale > 1.02

        // Compute UV metrics (same formula as makeZoomUniforms in MetalRenderer)
        let uvScale = Float(1.0 / zoomScale)
        let viewSize = view.bounds.size
        guard viewSize.width > 0 else { return }
        let panNX  = Float(panOffset.x / viewSize.width)
        let panNY  = Float(panOffset.y / viewSize.height)
        let uvOX   = 0.5 * (1 - uvScale) - panNX * uvScale
        let uvOY   = 0.5 * (1 - uvScale) - panNY * uvScale
        let uvOff  = SIMD2<Float>(uvOX, uvOY)

        // Update indicator arrows
        zoomIndicator.update(uvOffset: uvOff, uvScale: uvScale)
        UIView.animate(withDuration: 0.2) {
            self.zoomIndicator.alpha = isZoomed ? 0.95 : 0
        }
        zoomIndicator.isUserInteractionEnabled = isZoomed

    }

    // MARK: - VM Switch Hotkey

    var vmSwitchHotkey: ServerConnection.VMSwitchModifier = .control

    /// Returns true if the VM-switch modifier key is currently held,
    /// based on the configured hotkey for this session.
    private func switchModifierHeld(in event: UIPressesEvent?) -> Bool {
        guard vmSwitchHotkey != .disabled, let all = event?.allPresses else { return false }
        return all.contains { press in
            guard let key = press.key else { return false }
            switch vmSwitchHotkey {
            case .control:
                return key.modifierFlags.contains(.control) ||
                       key.keyCode == .keyboardLeftControl ||
                       key.keyCode == .keyboardRightControl
            case .command:
                return key.modifierFlags.contains(.command) ||
                       key.keyCode == .keyboardLeftGUI ||
                       key.keyCode == .keyboardRightGUI
            case .option:
                return key.modifierFlags.contains(.alternate) ||
                       key.keyCode == .keyboardLeftAlt ||
                       key.keyCode == .keyboardRightAlt
            case .disabled:
                return false
            }
        }
    }

    private func isSwitchModifier(_ key: UIKey) -> Bool {
        switch vmSwitchHotkey {
        case .control:  return key.modifierFlags.contains(.control)
        case .command:  return key.modifierFlags.contains(.command)
        case .option:   return key.modifierFlags.contains(.alternate)
        case .disabled: return false
        }
    }

    // MARK: - Keyboard Events

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let switchHeld = switchModifierHeld(in: event)

        for press in presses {
            guard let key = press.key else {
                super.pressesBegan([press], with: event)
                continue
            }
            // Configured modifier + Left/Right: switch VM sessions (not forwarded to VM)
            if switchHeld || isSwitchModifier(key) {
                if key.keyCode == .keyboardLeftArrow {
                    delegate?.displayViewDidFourFingerSwipe(self, direction: .right)
                    continue
                } else if key.keyCode == .keyboardRightArrow {
                    delegate?.displayViewDidFourFingerSwipe(self, direction: .left)
                    continue
                }
            }
            delegate?.displayView(self, keyDown: key)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else {
                super.pressesEnded([press], with: event)
                continue
            }
            // Consume key-up for intercepted shortcuts
            if isSwitchModifier(key),
               key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow {
                continue
            }
            delegate?.displayView(self, keyUp: key)
        }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesChanged(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else {
                super.pressesCancelled([press], with: event)
                continue
            }
            if key.modifierFlags.contains(.control),
               key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow {
                continue
            }
            delegate?.displayView(self, keyUp: key)
        }
    }

    // MARK: - Touch Events (forwarded to delegate)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = viewPointToDisplayPoint(touch.location(in: view))
        else { return }
        delegate?.displayView(self, touchBegan: touch, at: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = viewPointToDisplayPoint(touch.location(in: view))
        else { return }
        delegate?.displayView(self, touchMoved: touch, at: point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = viewPointToDisplayPoint(touch.location(in: view))
        else { return }
        delegate?.displayView(self, touchEnded: touch, at: point)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = viewPointToDisplayPoint(touch.location(in: view))
        else { return }
        delegate?.displayView(self, touchCancelled: touch, at: point)
    }
}

// MARK: - Zoom indicator

/// Circle with 4 directional arrows whose alpha reflects how far from each edge the
/// current viewport is. Dim = at the edge (no more content that way). Tap to reset zoom.
private final class ZoomIndicatorView: UIView {

    var onTap: (() -> Void)?

    private let upIV    = makeArrow("arrow.up")
    private let downIV  = makeArrow("arrow.down")
    private let leftIV  = makeArrow("arrow.left")
    private let rightIV = makeArrow("arrow.right")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 26
        layer.cornerCurve = .circular
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.borderWidth = 0.5

        for iv in [upIV, downIV, leftIV, rightIV] { addSubview(iv) }
        NSLayoutConstraint.activate([
            upIV.centerXAnchor.constraint(equalTo: centerXAnchor),
            upIV.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            downIV.centerXAnchor.constraint(equalTo: centerXAnchor),
            downIV.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            leftIV.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftIV.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            rightIV.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightIV.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    private static func makeArrow(_ name: String) -> UIImageView {
        let cfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let iv = UIImageView(image: UIImage(systemName: name, withConfiguration: cfg))
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }

    /// Update arrow alphas based on current UV viewport position.
    /// Each arrow is bright when there is content beyond that edge, dim when at the boundary.
    func update(uvOffset: SIMD2<Float>, uvScale: Float) {
        let threshold: Float = 0.08
        func alpha(_ distance: Float) -> CGFloat {
            // distance = how far the viewport is from this edge in UV space (0 = at edge)
            CGFloat(min(max(distance, 0) / threshold, 1.0) * 0.75 + 0.25)
        }
        upIV.alpha    = alpha(uvOffset.y)
        downIV.alpha  = alpha(1 - uvOffset.y - uvScale)
        leftIV.alpha  = alpha(uvOffset.x)
        rightIV.alpha = alpha(1 - uvOffset.x - uvScale)
    }
}

// MARK: - Software keyboard input field

/// Hidden UIView that hosts the iOS software keyboard via UIKeyInput.
/// Using UIView directly (not UITextField) ensures insertText is called without
/// UITextField's internal text-storage machinery interfering.
final class SoftKeyboardField: UIView, UIKeyInput, UITextInputTraits {
    var onInsertText: ((String) -> Void)?
    var onScancode: ((UInt32) -> Void)?
    var onModifierDown: ((UInt32) -> Void)?
    var onModifierUp: ((UInt32) -> Void)?
    weak var parentVC: MetalDisplayViewController?

    override var canBecomeFirstResponder: Bool { true }

    private lazy var accessory: KeyboardAccessoryView = {
        let v = KeyboardAccessoryView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        v.onTapScancode = { [weak self] sc in
            self?.onScancode?(sc)
            self?.accessory.releaseAllModifiers()
        }
        v.onModifierDown = { [weak self] sc in self?.onModifierDown?(sc) }
        v.onModifierUp   = { [weak self] sc in self?.onModifierUp?(sc) }
        v.onHideKeyboard = { [weak self] in self?.resignFirstResponder() }
        return v
    }()

    override var inputAccessoryView: UIView? { accessory }

    // UIKeyInput
    var hasText: Bool { false }

    func insertText(_ text: String) {
        onInsertText?(text)
        accessory.releaseAllModifiers()
    }

    func deleteBackward() {
        onInsertText?("\u{08}")
        accessory.releaseAllModifiers()
    }

    // UITextInputTraits — disable all iOS text-assistance features
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    // Forward hardware keyboard events to the parent VC so it keeps working
    // even while this view is first responder.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        parentVC?.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        parentVC?.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        parentVC?.pressesCancelled(presses, with: event)
    }
}
