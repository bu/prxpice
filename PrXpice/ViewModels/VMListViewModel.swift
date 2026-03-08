import Foundation
import Combine

@MainActor
final class VMListViewModel: ObservableObject {
    @Published private(set) var vms: [VMInfo] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var poweringVMs: Set<String> = []

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
            // Check all QEMU VMs (not just running) so stopped VMs show up if configured
            let allQemu = allVMs.filter { $0.type == .qemu }
            var spiceVMIDs = Set<String>()
            await withTaskGroup(of: (String, Bool).self) { group in
                for vm in allQemu {
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

            // Sort: running SPICE first, then stopped SPICE, then by name
            vms = allVMs.sorted { a, b in
                if a.supportsSpice && !b.supportsSpice { return true }
                if !a.supportsSpice && b.supportsSpice { return false }
                if a.hasSpiceConfig && !b.hasSpiceConfig { return true }
                if !a.hasSpiceConfig && b.hasSpiceConfig { return false }
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

    func startVM(_ vm: VMInfo) async {
        poweringVMs.insert(vm.id)
        do {
            try await apiClient.startVM(node: vm.node, vmid: vm.vmid)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await loadVMs()
        } catch {
            self.error = error.localizedDescription
        }
        poweringVMs.remove(vm.id)
    }

    func stopVM(_ vm: VMInfo) async {
        poweringVMs.insert(vm.id)
        do {
            try await apiClient.stopVM(node: vm.node, vmid: vm.vmid)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await loadVMs()
        } catch {
            self.error = error.localizedDescription
        }
        poweringVMs.remove(vm.id)
    }
}
