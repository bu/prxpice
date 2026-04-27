import UIKit

/// Bridge between the per-VM `MetalDisplayViewController` (which owns the
/// capture-mode state) and the global `AppDelegate.buildMenu(with:)` override,
/// which needs to know whether to remove standard menus.
///
/// Setting `isActive` triggers a menu rebuild on the next runloop tick so the
/// macOS menu bar reflects the new state.
@MainActor
final class CaptureModeBus {
    static let shared = CaptureModeBus()
    private init() {}

    private(set) var isActive: Bool = false

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        #if targetEnvironment(macCatalyst)
        UIMenuSystem.main.setNeedsRebuild()
        #endif
    }
}
