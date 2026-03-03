import Foundation
import CSpiceBridge

/// Manages a dedicated pthread for the GLib main loop.
/// SPICE callbacks fire on this thread; display updates go directly to Metal
/// (thread-safe), while UI state changes dispatch to main queue.
final class GLibRunLoopIntegration {
    private var thread: Thread?
    private var isRunning = false

    /// Starts the GLib main loop on a dedicated background thread.
    func start(session: OpaquePointer) {
        guard !isRunning else { return }
        isRunning = true

        // Store as raw pointer for the thread
        let sessionPtr = session

        thread = Thread {
            Thread.current.name = "com.prxpice.glib-mainloop"
            Thread.current.qualityOfService = .userInteractive

            Log.spice.info("GLib main loop starting")
            spice_bridge_run_loop(sessionPtr)
            Log.spice.info("GLib main loop exited")
        }
        thread?.start()
    }

    /// Signals the GLib main loop to quit. Thread-safe.
    func stop(session: OpaquePointer) {
        guard isRunning else { return }
        isRunning = false
        spice_bridge_quit_loop(session)
        thread = nil
    }
}
