import SwiftUI

struct VMListView: View {
    let connection: ServerConnection
    let connectionStore: ConnectionStore

    @StateObject private var viewModel: VMListViewModel
    @State private var selectedVM: VMInfo?
    @State private var spiceConfig: SpiceConfig?

    init(connection: ServerConnection, connectionStore: ConnectionStore) {
        self.connection = connection
        self.connectionStore = connectionStore
        _viewModel = StateObject(wrappedValue: VMListViewModel(
            connection: connection,
            connectionStore: connectionStore
        ))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.vms.isEmpty {
                ProgressView("Connecting...")
            } else if let error = viewModel.error {
                errorView(error)
            } else if viewModel.vms.isEmpty {
                ContentUnavailableView(
                    "No VMs Found",
                    systemImage: "desktopcomputer",
                    description: Text("No QEMU virtual machines found on this server.")
                )
            } else {
                vmList
            }
        }
        .navigationTitle(connection.name.isEmpty ? connection.hostname : connection.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.loadVMs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task {
            await viewModel.authenticate()
        }
        .fullScreenCover(item: $selectedVM) { vm in
            if let config = spiceConfig {
                VMDisplayView(vm: vm, spiceConfig: config)
            }
        }
    }

    private var vmList: some View {
        List(viewModel.vms) { vm in
            Button {
                connectToVM(vm)
            } label: {
                VMRow(vm: vm)
            }
            .disabled(!vm.supportsSpice)
        }
        .refreshable {
            await viewModel.loadVMs()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Connection Error")
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.authenticate() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func connectToVM(_ vm: VMInfo) {
        Task {
            do {
                spiceConfig = try await viewModel.getSpiceConfig(for: vm)
                selectedVM = vm
            } catch {
                viewModel.error = error.localizedDescription
            }
        }
    }
}

private struct VMRow: View {
    let vm: VMInfo

    var body: some View {
        HStack {
            Image(systemName: vm.type == .qemu ? "desktopcomputer" : "shippingbox")
                .frame(width: 32)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("VMID: \(vm.vmid)")
                    if let cpus = vm.cpus {
                        Text("\(cpus) CPU")
                    }
                    if let mem = vm.maxmem {
                        Text(formatBytes(mem))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(vm.status.rawValue.capitalized)
                .font(.caption.bold())
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
        .opacity(vm.supportsSpice ? 1.0 : 0.5)
    }

    private var statusColor: Color {
        switch vm.status {
        case .running: return .green
        case .stopped: return .red
        case .paused: return .orange
        case .unknown: return .gray
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
