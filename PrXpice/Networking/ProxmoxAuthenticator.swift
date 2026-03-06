import Foundation

/// Authentication credentials for the Proxmox API.
enum ProxmoxCredentials {
    /// Username/password auth - exchanges for a ticket + CSRF token
    case password(username: String, password: String)
    /// API token auth - uses token directly in Authorization header
    case apiToken(tokenID: String, secret: String)
}

/// Manages authentication state for Proxmox API requests.
/// Supports both password-based (ticket) and API token authentication.
actor ProxmoxAuthenticator {
    private var ticket: String?
    private var csrfToken: String?
    private var tokenID: String?
    private var tokenSecret: String?
    private var ticketExpiry: Date?

    private let baseURL: URL
    private let urlSession: URLSession

    struct AuthResponse: Codable {
        let data: AuthData

        struct AuthData: Codable {
            let ticket: String
            let CSRFPreventionToken: String
            let username: String
        }
    }

    init(baseURL: URL, urlSession: URLSession) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// Authenticates with the given credentials.
    /// For password auth, this exchanges credentials for a ticket.
    /// For API token auth, this just stores the token.
    func authenticate(with credentials: ProxmoxCredentials) async throws {
        switch credentials {
        case .password(let username, let password):
            try await authenticateWithPassword(username: username, password: password)
        case .apiToken(let tokenID, let secret):
            self.tokenID = tokenID
            self.tokenSecret = secret
        }
    }

    /// Applies auth headers to a URLRequest.
    func authorize(_ request: inout URLRequest) {
        if let tokenID = tokenID, let secret = tokenSecret {
            // API token auth
            request.setValue("PVEAPIToken=\(tokenID)=\(secret)", forHTTPHeaderField: "Authorization")
        } else if let ticket = ticket {
            // Cookie-based ticket auth
            request.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
            if let csrf = csrfToken {
                request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken")
            }
        }
    }

    /// Returns true if the current ticket is still valid (with 5-minute buffer).
    var isAuthenticated: Bool {
        if tokenID != nil && tokenSecret != nil {
            return true
        }
        guard let expiry = ticketExpiry else { return false }
        return Date() < expiry.addingTimeInterval(-300) // 5 min buffer
    }

    // MARK: - Private

    private func authenticateWithPassword(username: String, password: String) async throws {
        let url = ProxmoxEndpoints.ticket(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(username.urlEncoded)&password=\(password.urlEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw ProxmoxError.authenticationFailed
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        self.ticket = authResponse.data.ticket
        self.csrfToken = authResponse.data.CSRFPreventionToken
        // PVE tickets are valid for 2 hours
        self.ticketExpiry = Date().addingTimeInterval(7200)

        Log.network.info("Authenticated as \(authResponse.data.username)")
    }
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

enum ProxmoxError: LocalizedError {
    case authenticationFailed
    case requestFailed(statusCode: Int)
    case invalidResponse
    case spiceNotAvailable
    case serverError(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication failed. Check your credentials."
        case .requestFailed(let code):
            return "Request failed with status \(code)"
        case .invalidResponse:
            return "Invalid response from server"
        case .spiceNotAvailable:
            return "SPICE is not available for this VM"
        case .serverError(let message):
            return message
        case .notConnected:
            return "Not connected to server"
        }
    }
}
