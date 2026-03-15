import SwiftUI

struct VMListView: View {
    let connection: ServerConnection
    let connectionStore: ConnectionStore

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: VMListViewModel
    @State private var isConnecting = false

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
            } else if viewModel.vms.filter({ $0.hasSpiceConfig }).isEmpty {
                ContentUnavailableView(
                    "No SPICE VMs Found",
                    systemImage: "desktopcomputer",
                    description: Text("No QEMU VMs with SPICE display configured on this server.")
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
    }

    private var vmList: some View {
        List(viewModel.vms.filter { $0.hasSpiceConfig }) { vm in
            VMRow(
                vm: vm,
                isPowering: viewModel.poweringVMs.contains(vm.id),
                onConnect: vm.supportsSpice ? { connectToVM(vm) } : nil,
                onPowerToggle: {
                    Task {
                        if vm.status == .running {
                            await viewModel.stopVM(vm)
                        } else {
                            await viewModel.startVM(vm)
                        }
                    }
                }
            )
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
        // If already open, switch to it
        if let existingIndex = sessionStore.sessions.firstIndex(where: { $0.vm.vmid == vm.vmid && $0.vm.node == vm.node }) {
            sessionStore.activeSessionIndex = existingIndex
            sessionStore.showMultiVM = true
            return
        }
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            do {
                let config = try await viewModel.getSpiceConfig(for: vm)
                let session = VMSession(vm: vm, spiceConfig: config, vmSwitchHotkey: connection.vmSwitchHotkey)
                sessionStore.sessions.append(session)
                sessionStore.activeSessionIndex = sessionStore.sessions.count - 1
                sessionStore.showMultiVM = true
            } catch {
                viewModel.error = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

private struct VMRow: View {
    let vm: VMInfo
    let isPowering: Bool
    let onConnect: (() -> Void)?
    let onPowerToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.type == .qemu ? "desktopcomputer" : "shippingbox")
                .frame(width: 32)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("VMID: \(String(vm.vmid))")
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

            // Power button
            Button(action: onPowerToggle) {
                if isPowering {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: vm.status == .running ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(vm.status == .running ? .red : .green)
                        .frame(width: 28, height: 28)
                        .background(
                            (vm.status == .running ? Color.red : Color.green).opacity(0.12),
                            in: Circle()
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(isPowering)

            // Status badge
            Text(vm.status.rawValue.capitalized)
                .font(.caption.bold())
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onConnect?()
        }
        .opacity(onConnect == nil ? 0.75 : 1.0)
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
