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
    func displayViewSize(_ vc: MetalDisplayViewController) -> CGSize
}

final class MetalDisplayViewController: UIViewController {
    private(set) var renderer: MetalRenderer?
    private var displayLink: CADisplayLink?
    private var metalLayer: CAMetalLayer!

    weak var delegate: MetalDisplayViewDelegate?

    // Display scaling
    private var displayScale: CGFloat = 1.0
    private var displayOffset: CGPoint = .zero

    // Zoom/pan state
    private(set) var zoomScale: CGFloat = 1.0
    private(set) var panOffset: CGPoint = .zero
    private var minZoom: CGFloat = 0.5
    private var maxZoom: CGFloat = 4.0

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
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.presentsWithTransaction = false
        view.layer.addSublayer(metalLayer)

        renderer = MetalRenderer(device: device)

        setupGestureRecognizers()
        startDisplayLink()
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        guard let renderer = renderer,
              let drawable = metalLayer.nextDrawable()
        else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        renderer.draw(in: drawable, renderPassDescriptor: passDescriptor)
    }

    // MARK: - Coordinate Transform

    /// Updates the transform from view coordinates to VM display coordinates.
    /// Maintains aspect ratio, centering the display in the view.
    private func updateDisplayTransform() {
        guard let renderer = renderer,
              renderer.displayWidth > 0, renderer.displayHeight > 0
        else { return }

        let vmSize = CGSize(width: renderer.displayWidth, height: renderer.displayHeight)
        let viewSize = view.bounds.size

        let scaleX = viewSize.width / vmSize.width
        let scaleY = viewSize.height / vmSize.height
        displayScale = min(scaleX, scaleY) * zoomScale

        let scaledWidth = vmSize.width * displayScale
        let scaledHeight = vmSize.height * displayScale

        displayOffset = CGPoint(
            x: (viewSize.width - scaledWidth) / 2 + panOffset.x,
            y: (viewSize.height - scaledHeight) / 2 + panOffset.y
        )
    }

    /// Converts a view-space point to VM display coordinates.
    func viewPointToDisplayPoint(_ viewPoint: CGPoint) -> CGPoint? {
        guard displayScale > 0 else { return nil }

        let x = (viewPoint.x - displayOffset.x) / displayScale
        let y = (viewPoint.y - displayOffset.y) / displayScale

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

        view.isMultipleTouchEnabled = true
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let newScale = zoomScale * gesture.scale
            zoomScale = min(max(newScale, minZoom), maxZoom)
            gesture.scale = 1.0
            updateDisplayTransform()
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
            updateDisplayTransform()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Reset zoom and pan
        zoomScale = 1.0
        panOffset = .zero
        UIView.animate(withDuration: 0.25) {
            self.updateDisplayTransform()
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
