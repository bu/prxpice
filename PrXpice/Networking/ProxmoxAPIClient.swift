import Foundation

/// Async/await client for the Proxmox VE REST API.
/// Handles auth, node enumeration, VM listing, and SPICE proxy config retrieval.
final class ProxmoxAPIClient {
    private let baseURL: URL
    private let authenticator: ProxmoxAuthenticator
    private let urlSession: URLSession

    init(connection: ServerConnection) {
        self.baseURL = connection.baseURL

        // Trust self-signed certs (common in PVE setups)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let delegate = InsecureTLSDelegate()
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.authenticator = ProxmoxAuthenticator(baseURL: baseURL, urlSession: urlSession)
    }

    /// Authenticates with the server.
    func authenticate(credentials: ProxmoxCredentials) async throws {
        try await authenticator.authenticate(with: credentials)
    }

    /// Lists all nodes in the cluster.
    func listNodes() async throws -> [NodeInfo] {
        let url = ProxmoxEndpoints.nodes(baseURL: baseURL)
        let response: PVEResponse<[NodeInfo]> = try await get(url: url)
        return response.data
    }

    /// Lists QEMU VMs on a specific node.
    func listQemuVMs(node: String) async throws -> [VMInfo] {
        let url = ProxmoxEndpoints.qemuVMs(baseURL: baseURL, node: node)
        let response: PVEResponse<[VMInfo]> = try await get(url: url)
        return response.data
    }

    /// Lists LXC containers on a specific node.
    func listLXCContainers(node: String) async throws -> [VMInfo] {
        let url = ProxmoxEndpoints.lxcContainers(baseURL: baseURL, node: node)
        let response: PVEResponse<[VMInfo]> = try await get(url: url)
        return response.data
    }

    /// Gets SPICE connection config for a VM.
    /// Returns the virt-viewer format config string, parsed into SpiceConfig.
    func getSpiceConfig(node: String, vmid: Int) async throws -> SpiceConfig {
        let url = ProxmoxEndpoints.spiceProxy(baseURL: baseURL, node: node, vmid: vmid)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // spiceproxy requires a proxy parameter for the viewer
        request.httpBody = "proxy=".data(using: .utf8)

        await authenticator.authorize(&request)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw ProxmoxError.spiceNotAvailable
        }

        // The response is JSON with a data field containing the virt-viewer config
        let spiceResponse = try JSONDecoder().decode(PVEResponse<SpiceProxyData>.self, from: data)

        // Build virt-viewer format string from the response fields
        var configLines = ["[virt-viewer]", "type=spice"]
        configLines.append("host=\(spiceResponse.data.host)")
        configLines.append("port=\(spiceResponse.data.port ?? "")")
        if let tlsPort = spiceResponse.data.tlsPort {
            configLines.append("tls-port=\(tlsPort)")
        }
        configLines.append("password=\(spiceResponse.data.password)")
        if let ca = spiceResponse.data.ca {
            configLines.append("ca=\(ca)")
        }
        if let subject = spiceResponse.data.hostSubject {
            configLines.append("host-subject=\(subject)")
        }
        if let proxy = spiceResponse.data.proxy, !proxy.isEmpty {
            configLines.append("proxy=\(proxy)")
        }
        if let sc = spiceResponse.data.secureChannels {
            configLines.append("secure-channels=\(sc)")
        }

        let configString = configLines.joined(separator: "\n")
        guard let config = SpiceConfig.parse(from: configString) else {
            throw ProxmoxError.invalidResponse
        }

        return config
    }

    // MARK: - Private

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        await authenticator.authorize(&request)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxmoxError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw ProxmoxError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Response Types

struct PVEResponse<T: Decodable>: Decodable {
    let data: T
}

struct NodeInfo: Codable, Identifiable {
    let node: String
    let status: String
    let cpu: Double?
    let maxcpu: Int?
    let mem: Int64?
    let maxmem: Int64?

    var id: String { node }
}

struct SpiceProxyData: Codable {
    let host: String
    let port: String?
    let tlsPort: String?
    let password: String
    let ca: String?
    let hostSubject: String?
    let proxy: String?
    let secureChannels: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case host, port, password, ca, proxy, type
        case tlsPort = "tls-port"
        case hostSubject = "host-subject"
        case secureChannels = "secure-channels"
    }
}

// MARK: - TLS Delegate (for self-signed certs)

private class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
