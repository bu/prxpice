import Foundation
import CSpiceBridge

/// Manages a dedicated pthread for the GLib main loop.
/// SPICE callbacks fire on this thread; display updates go directly to Metal
/// (thread-safe), while UI state changes dispatch to main queue.
final class GLibRunLoopIntegration {
    private var thread: Thread?
    private var isRunning = false
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private var started = false

    /// Starts the GLib main loop on a dedicated background thread.
    func start(session: OpaquePointer) {
        guard !isRunning else { return }
        isRunning = true
        started = true

        let sessionPtr = session
        thread = Thread { [weak self] in
            Thread.current.name = "com.prxpice.glib-mainloop"
            Thread.current.qualityOfService = .userInteractive
            Log.spice.info("GLib main loop starting")
            spice_bridge_run_loop(sessionPtr)
            Log.spice.info("GLib main loop exited")
            self?.exitSemaphore.signal()
        }
        thread?.start()
    }

    /// Signals the GLib main loop to quit and waits (with timeout) for the
    /// thread to fully exit. Must NOT be called on the main thread — use
    /// a background queue.
    func stopAndWait(session: OpaquePointer) {
        guard isRunning else { return }
        isRunning = false
        spice_bridge_quit_loop(session)
        if started {
            _ = exitSemaphore.wait(timeout: .now() + 5.0)
        }
        thread = nil
    }
}
