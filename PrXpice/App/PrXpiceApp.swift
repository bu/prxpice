import SwiftUI

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
        }
    }
}
