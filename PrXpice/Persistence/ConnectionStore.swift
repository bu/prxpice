import Foundation
import Combine

/// Persists saved server connections to UserDefaults.
/// Passwords and API token secrets are stored in Keychain.
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [ServerConnection] = []

    private let storageKey = "com.prxpice.connections"

    init() {
        load()
    }

    func add(_ connection: ServerConnection) {
        connections.append(connection)
        save()
    }

    func update(_ connection: ServerConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        save()
    }

    func delete(_ connection: ServerConnection) {
        connections.removeAll { $0.id == connection.id }
        // Remove stored credentials
        KeychainHelper.delete(key: keychainKey(for: connection))
        save()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { connections[$0] }
        for conn in toDelete {
            KeychainHelper.delete(key: keychainKey(for: conn))
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Saves a password or API token secret in the Keychain for a connection.
    func saveSecret(_ secret: String, for connection: ServerConnection) {
        KeychainHelper.save(key: keychainKey(for: connection), string: secret)
    }

    /// Retrieves the stored password or API token secret for a connection.
    func loadSecret(for connection: ServerConnection) -> String? {
        KeychainHelper.loadString(key: keychainKey(for: connection))
    }

    /// Updates the lastConnected timestamp for a connection.
    func markConnected(_ connection: ServerConnection) {
        var updated = connection
        updated.lastConnected = Date()
        update(updated)
    }

    // MARK: - Private

    private func keychainKey(for connection: ServerConnection) -> String {
        "connection.\(connection.id.uuidString)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerConnection].self, from: data)
        else { return }
        connections = decoded
    }
}
