import SwiftUI

@main
struct PrXpiceApp: App {
    @StateObject private var connectionStore = ConnectionStore()

    init() {
        CrashLogger.install()
        CrashLogger.pruneOldLogs(olderThan: 7)
    }

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(connectionStore)
        }
    }
}
