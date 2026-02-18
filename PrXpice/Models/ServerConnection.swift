import Foundation

struct ServerConnection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int
    var authMethod: AuthMethod
    var username: String
    /// For API token auth, this is the token ID (e.g., "user@pam!tokenname")
    var tokenID: String
    /// Stored in Keychain, not serialized here
    var lastConnected: Date?

    enum AuthMethod: String, Codable, CaseIterable {
        case password
        case apiToken
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = 8006,
        authMethod: AuthMethod = .password,
        username: String = "root@pam",
        tokenID: String = "",
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.authMethod = authMethod
        self.username = username
        self.tokenID = tokenID
        self.lastConnected = lastConnected
    }

    var baseURL: URL {
        URL(string: "https://\(hostname):\(port)")!
    }
}
