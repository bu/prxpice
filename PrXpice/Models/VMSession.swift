import Foundation

/// An active VM connection — holds the VM info, SPICE config, and its live ViewModel.
/// Multiple sessions can coexist, each maintaining an independent SPICE connection.
@MainActor
final class VMSession: Identifiable, ObservableObject {
    let id = UUID()
    let vm: VMInfo
    let spiceConfig: SpiceConfig
    let viewModel: VMDisplayViewModel
    let vmSwitchHotkey: ServerConnection.VMSwitchModifier

    init(vm: VMInfo, spiceConfig: SpiceConfig, vmSwitchHotkey: ServerConnection.VMSwitchModifier = .control) {
        self.vm = vm
        self.spiceConfig = spiceConfig
        self.viewModel = VMDisplayViewModel(vm: vm)
        self.vmSwitchHotkey = vmSwitchHotkey
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
