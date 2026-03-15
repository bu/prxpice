import SwiftUI

struct AddConnectionView: View {
    @ObservedObject var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var authMethod: ServerConnection.AuthMethod
    @State private var username: String
    @State private var tokenID: String
    @State private var secret: String
    private let editingID: UUID?
    private var isEditing: Bool { editingID != nil }

    init(connectionStore: ConnectionStore, editing: ServerConnection? = nil) {
        self.connectionStore = connectionStore
        self.editingID = editing?.id

        _name = State(initialValue: editing?.name ?? "")
        _hostname = State(initialValue: editing?.hostname ?? "")
        _port = State(initialValue: String(editing?.port ?? 8006))
        _authMethod = State(initialValue: editing?.authMethod ?? .password)
        _username = State(initialValue: editing?.username ?? "root@pam")
        _tokenID = State(initialValue: editing?.tokenID ?? "")

        // Load existing secret if editing
        if let conn = editing {
            _secret = State(initialValue: connectionStore.loadSecret(for: conn) ?? "")
        } else {
            _secret = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Display Name", text: $name)
                        .textContentType(.organizationName)
                        .autocorrectionDisabled()
                    TextField("Hostname or IP", text: $hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("Port", text: Binding(
                        get: { port },
                        set: { port = $0.filter(\.isNumber) }
                    ))
                    .keyboardType(.numberPad)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Password").tag(ServerConnection.AuthMethod.password)
                        Text("API Token").tag(ServerConnection.AuthMethod.apiToken)
                    }

                    switch authMethod {
                    case .password:
                        TextField("Username", text: $username)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $secret)
                    case .apiToken:
                        TextField("Token ID (user@realm!name)", text: $tokenID)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        SecureField("Token Secret", text: $secret)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !hostname.isEmpty && Int(port) != nil && !secret.isEmpty
    }

    private func save() {
        let portNum = Int(port) ?? 8006

        var connection = ServerConnection(
            id: editingID ?? UUID(),
            name: name,
            hostname: hostname,
            port: portNum,
            authMethod: authMethod,
            username: username,
            tokenID: tokenID
        )

        if isEditing {
            connectionStore.update(connection)
        } else {
            connectionStore.add(connection)
        }

        connectionStore.saveSecret(secret, for: connection)
        dismiss()
    }
}
