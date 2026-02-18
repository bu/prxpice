import SwiftUI

@main
struct PrXpiceApp: App {
    @StateObject private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(connectionStore)
        }
    }
}
