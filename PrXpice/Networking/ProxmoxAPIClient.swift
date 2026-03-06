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
        return response.data.map { var vm = $0; vm.node = node; return vm }
    }

    /// Lists LXC containers on a specific node.
    func listLXCContainers(node: String) async throws -> [VMInfo] {
        let url = ProxmoxEndpoints.lxcContainers(baseURL: baseURL, node: node)
        let response: PVEResponse<[VMInfo]> = try await get(url: url)
        return response.data.map { var vm = $0; vm.node = node; return vm }
    }

    /// Gets VM hardware config — used to check if SPICE display (QXL) is configured.
    func getVMConfig(node: String, vmid: Int) async throws -> VMConfigData {
        let url = ProxmoxEndpoints.vmConfig(baseURL: baseURL, node: node, vmid: vmid)
        let response: PVEResponse<VMConfigData> = try await get(url: url)
        return response.data
    }

    /// Gets SPICE connection config for a VM.
    /// Returns the virt-viewer format config string, parsed into SpiceConfig.
    func getSpiceConfig(node: String, vmid: Int) async throws -> SpiceConfig {
        let url = ProxmoxEndpoints.spiceProxy(baseURL: baseURL, node: node, vmid: vmid)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Pass the server host as proxy so PVE knows where to direct the client
        let proxyHost = baseURL.host ?? ""
        request.httpBody = "proxy=\(proxyHost)".data(using: .utf8)

        await authenticator.authorize(&request)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxmoxError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Try to extract the server's error message
            if let errorResponse = try? JSONDecoder().decode(PVEErrorResponse.self, from: data),
               let message = errorResponse.errors?.values.first ?? errorResponse.message {
                throw ProxmoxError.serverError(message)
            }
            throw ProxmoxError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let spiceResponse = try JSONDecoder().decode(PVEResponse<SpiceProxyData>.self, from: data)
        let d = spiceResponse.data

        // port or tls-port must be present to connect
        guard let port = d.port ?? d.tlsPort else {
            throw ProxmoxError.invalidResponse
        }

        return SpiceConfig(
            host: d.host,
            port: port,
            tlsPort: d.tlsPort,
            password: d.password,
            ca: d.ca,
            hostSubject: d.hostSubject,
            proxy: d.proxy,
            secureChannels: d.secureChannels
        )
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

struct PVEErrorResponse: Decodable {
    let errors: [String: String]?
    let message: String?
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
    let port: Int?
    let tlsPort: Int?
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

struct VMConfigData: Decodable {
    let vga: String?

    /// True if the VM has a QXL display (required for SPICE).
    var hasSpiceDisplay: Bool {
        guard let vga else { return false }
        // vga can be "qxl", "qxl2", "qxl4", or with options like "qxl,memory=16384"
        return vga.hasPrefix("qxl")
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
