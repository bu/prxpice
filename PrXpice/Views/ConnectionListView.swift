import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var showingAddSheet = false
    @State private var editingConnection: ServerConnection?
    @State private var selectedConnection: ServerConnection?

    var body: some View {
        NavigationStack {
            Group {
                if connectionStore.connections.isEmpty {
                    emptyState
                } else {
                    connectionList
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                if !sessionStore.sessions.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            sessionStore.showMultiVM = true
                        } label: {
                            Label("\(sessionStore.sessions.count) Active", systemImage: "desktopcomputer.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddConnectionView(connectionStore: connectionStore)
            }
            .sheet(item: $editingConnection) { connection in
                AddConnectionView(connectionStore: connectionStore, editing: connection)
            }
            .navigationDestination(item: $selectedConnection) { connection in
                VMListView(connection: connection, connectionStore: connectionStore)
            }
        }
        .fullScreenCover(isPresented: $sessionStore.showMultiVM) {
            MultiVMContainerView(sessions: $sessionStore.sessions, currentIndex: $sessionStore.activeSessionIndex)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Servers")
                .font(.title2.bold())
            Text("Add a Proxmox VE server to get started.")
                .foregroundStyle(.secondary)
            Button("Add Server") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var connectionList: some View {
        List {
            ForEach(connectionStore.connections) { connection in
                Button {
                    selectedConnection = connection
                } label: {
                    ConnectionRow(connection: connection)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        connectionStore.delete(connection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingConnection = connection
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
            .onMove { source, destination in
                connectionStore.move(from: source, to: destination)
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: ServerConnection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.name.isEmpty ? connection.hostname : connection.name)
                    .font(.headline)
                Text("\(connection.hostname):\(String(connection.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: connection.authMethod == .apiToken ? "key" : "person")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if let lastConnected = connection.lastConnected {
                    Text(lastConnected, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
