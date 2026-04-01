import SwiftUI
import CSpiceBridge

@main
struct PrXpiceApp: App {
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var sessionStore = SessionStore()

    init() {
        CrashLogger.install()
        CrashLogger.pruneOldLogs(olderThan: 7)
    }

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(connectionStore)
                .environmentObject(sessionStore)
                #if targetEnvironment(macCatalyst)
                .onAppear {
                    // Enter true macOS full screen via NSApplication.sharedApplication.
                    // UIKit responder-chain toggleFullScreen: only zooms the window.
                    // EnterFullScreen() is implemented in AudioTapHelper.m with AppKit access.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        EnterFullScreen()
                    }
                }
                #endif
        }
    }
}
