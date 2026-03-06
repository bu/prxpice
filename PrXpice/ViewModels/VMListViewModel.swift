import Foundation
import Combine

@MainActor
final class VMListViewModel: ObservableObject {
    @Published private(set) var vms: [VMInfo] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let connection: ServerConnection
    private let apiClient: ProxmoxAPIClient
    private let connectionStore: ConnectionStore

    init(connection: ServerConnection, connectionStore: ConnectionStore) {
        self.connection = connection
        self.connectionStore = connectionStore
        self.apiClient = ProxmoxAPIClient(connection: connection)
    }

    func authenticate() async {
        isLoading = true
        error = nil

        do {
            let credentials: ProxmoxCredentials
            let secret = connectionStore.loadSecret(for: connection)

            switch connection.authMethod {
            case .password:
                guard let password = secret else {
                    error = "No password stored for this connection"
                    isLoading = false
                    return
                }
                credentials = .password(username: connection.username, password: password)

            case .apiToken:
                guard let tokenSecret = secret else {
                    error = "No API token secret stored for this connection"
                    isLoading = false
                    return
                }
                credentials = .apiToken(tokenID: connection.tokenID, secret: tokenSecret)
            }

            try await apiClient.authenticate(credentials: credentials)
            connectionStore.markConnected(connection)
            await loadVMs()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func loadVMs() async {
        isLoading = true
        error = nil

        do {
            let nodes = try await apiClient.listNodes()
            var allVMs: [VMInfo] = []

            for node in nodes {
                let qemuVMs = try await apiClient.listQemuVMs(node: node.node)
                allVMs.append(contentsOf: qemuVMs)
            }

            // Fetch VM configs in parallel to check for QXL/SPICE display
            let runningQemu = allVMs.filter { $0.type == .qemu && $0.status == .running }
            var spiceVMIDs = Set<String>()
            await withTaskGroup(of: (String, Bool).self) { group in
                for vm in runningQemu {
                    group.addTask { [apiClient] in
                        let hasSpice = (try? await apiClient.getVMConfig(node: vm.node, vmid: vm.vmid))?.hasSpiceDisplay ?? false
                        return (vm.id, hasSpice)
                    }
                }
                for await (vmID, hasSpice) in group {
                    if hasSpice { spiceVMIDs.insert(vmID) }
                }
            }

            // Apply SPICE display flag
            allVMs = allVMs.map { vm in
                var v = vm
                v.hasSpiceDisplay = spiceVMIDs.contains(vm.id)
                return v
            }

            // Sort: SPICE-capable running first, then by name
            vms = allVMs.sorted { a, b in
                if a.supportsSpice && !b.supportsSpice { return true }
                if !a.supportsSpice && b.supportsSpice { return false }
                return a.name < b.name
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func getSpiceConfig(for vm: VMInfo) async throws -> SpiceConfig {
        try await apiClient.getSpiceConfig(node: vm.node, vmid: vm.vmid)
    }
}
