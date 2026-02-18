import UIKit

/// Maps iOS touch gestures to SPICE mouse events.
///
/// Gesture mapping:
/// - Single tap → left click
/// - Long press → right click
/// - Touch drag → mouse move (absolute positioning)
/// - Two-finger scroll → scroll wheel
/// - Pinch → zoom (handled by MetalDisplayViewController)
final class TouchToMouseMapper {
    weak var inputHandler: SpiceInputHandler?

    // Tap detection
    private var touchDownTime: TimeInterval = 0
    private var touchDownLocation: CGPoint = .zero
    private var isDragging = false
    private var isLongPress = false

    // Long press threshold
    private let longPressThreshold: TimeInterval = 0.5
    private let dragThreshold: CGFloat = 5.0

    // Scroll tracking
    private var lastScrollY: CGFloat = 0
    private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 10.0

    // Timer for long press detection
    private var longPressTimer: Timer?

    func touchBegan(at point: CGPoint, timestamp: TimeInterval) {
        touchDownTime = timestamp
        touchDownLocation = point
        isDragging = false
        isLongPress = false

        // Move cursor to touch position
        inputHandler?.mouseMove(x: Int(point.x), y: Int(point.y))

        // Start long press timer
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
            self?.isLongPress = true
            // Right-click on long press
            self?.inputHandler?.mouseButtonPress(button: .right)
            self?.inputHandler?.mouseButtonRelease(button: .right)
        }
    }

    func touchMoved(at point: CGPoint, timestamp: TimeInterval) {
        let distance = hypot(point.x - touchDownLocation.x, point.y - touchDownLocation.y)

        if distance > dragThreshold && !isDragging {
            // Cancel long press on drag
            longPressTimer?.invalidate()
            longPressTimer = nil
            isDragging = true

            // Press left button to start drag
            inputHandler?.mouseButtonPress(button: .left)
        }

        // Move cursor
        inputHandler?.mouseMove(x: Int(point.x), y: Int(point.y))
    }

    func touchEnded(at point: CGPoint, timestamp: TimeInterval) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if isDragging {
            // Release drag
            inputHandler?.mouseMove(x: Int(point.x), y: Int(point.y))
            inputHandler?.mouseButtonRelease(button: .left)
        } else if !isLongPress {
            // Single tap → left click
            let tapDuration = timestamp - touchDownTime
            if tapDuration < longPressThreshold {
                inputHandler?.mouseButtonPress(button: .left)
                inputHandler?.mouseButtonRelease(button: .left)
            }
        }

        isDragging = false
        isLongPress = false
    }

    func touchCancelled() {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if isDragging {
            inputHandler?.mouseButtonRelease(button: .left)
        }

        isDragging = false
        isLongPress = false
    }

    /// Handle two-finger scroll gestures.
    /// Called from a UIPanGestureRecognizer with minimumNumberOfTouches = 2.
    func handleScroll(translationY: CGFloat) {
        scrollAccumulator += translationY

        while scrollAccumulator > scrollThreshold {
            inputHandler?.scrollDown()
            scrollAccumulator -= scrollThreshold
        }
        while scrollAccumulator < -scrollThreshold {
            inputHandler?.scrollUp()
            scrollAccumulator += scrollThreshold
        }
    }

    func resetScroll() {
        scrollAccumulator = 0
    }
}
