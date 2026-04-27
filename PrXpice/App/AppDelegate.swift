import UIKit

/// Hosts UIApplication-level overrides that SwiftUI's `App` cannot express.
///
/// On Mac Catalyst, `buildMenu(with:)` removes the standard menu items whose
/// Cmd-shortcuts (Cmd+W, Cmd+X/C/V, Cmd+M etc.) would otherwise be intercepted
/// by macOS while the user has input grab active on a VM.
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }

    #if targetEnvironment(macCatalyst)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard CaptureModeBus.shared.isActive else { return }

        // Remove every standard menu whose accelerators conflict with VM
        // shortcuts. The application menu is intentionally retained to keep
        // About / Preferences / Quit reachable (Cmd+Q is still attempted via
        // UIKeyCommand + wantsPriorityOverSystemBehavior in capture mode).
        builder.remove(menu: .file)
        builder.remove(menu: .edit)
        builder.remove(menu: .format)
        builder.remove(menu: .view)
        builder.remove(menu: .window)
        builder.remove(menu: .help)
    }
    #endif
}
