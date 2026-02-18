import Foundation
import Combine

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published var showingAddConnection = false
    @Published var editingConnection: ServerConnection?

    private let store: ConnectionStore

    init(store: ConnectionStore) {
        self.store = store
    }

    var connections: [ServerConnection] {
        store.connections
    }

    func deleteConnections(at offsets: IndexSet) {
        store.delete(at: offsets)
    }

    func moveConnections(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }
}
