import SwiftUI
import CSpiceBridge

@main
struct PrXpiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        CrashLogger.install()
        CrashLogger.pruneOldLogs(olderThan: 7)
    }

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(connectionStore)
                .environmentObject(sessionStore)
                .environmentObject(subscriptionManager)
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
