import Foundation

/// An active VM connection — holds the VM info, SPICE config, and its live ViewModel.
/// Multiple sessions can coexist, each maintaining an independent SPICE connection.
@MainActor
final class VMSession: Identifiable, ObservableObject {
    let id = UUID()
    let vm: VMInfo
    let spiceConfig: SpiceConfig
    let viewModel: VMDisplayViewModel

    init(vm: VMInfo, spiceConfig: SpiceConfig) {
        self.vm = vm
        self.spiceConfig = spiceConfig
        self.viewModel = VMDisplayViewModel(vm: vm)
    }

    func connect() {
        switch viewModel.connectionState {
        case .disconnected, .error:
            viewModel.connect(config: spiceConfig)
        default:
            break
        }
    }

    func disconnect() {
        viewModel.disconnect()
        viewModel.releaseAllModifiers()
    }
}
