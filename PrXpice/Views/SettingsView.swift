import SwiftUI

struct SettingsView: View {
    @AppStorage("vmSwitchHotkey") private var vmSwitchHotkey = ServerConnection.VMSwitchModifier.control

    var body: some View {
        Form {
            Section("Controls") {
                Picker("VM Switch Hotkey", selection: $vmSwitchHotkey) {
                    ForEach(ServerConnection.VMSwitchModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
