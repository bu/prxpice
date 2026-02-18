import SwiftUI

struct SettingsView: View {
    @AppStorage("preferredFrameRate") private var preferredFrameRate = 60
    @AppStorage("showInputToolbar") private var showInputToolbar = true
    @AppStorage("tapForLeftClick") private var tapForLeftClick = true
    @AppStorage("longPressForRightClick") private var longPressForRightClick = true
    @AppStorage("scrollSensitivity") private var scrollSensitivity = 1.0

    var body: some View {
        Form {
            Section("Display") {
                Picker("Max Frame Rate", selection: $preferredFrameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
            }

            Section("Input") {
                Toggle("Show Input Toolbar", isOn: $showInputToolbar)
                Toggle("Tap for Left Click", isOn: $tapForLeftClick)
                Toggle("Long Press for Right Click", isOn: $longPressForRightClick)

                VStack(alignment: .leading) {
                    Text("Scroll Sensitivity")
                    Slider(value: $scrollSensitivity, in: 0.25...3.0, step: 0.25)
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
