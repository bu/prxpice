import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [VMSession] = []
    @Published var activeSessionIndex: Int = 0
    @Published var showMultiVM: Bool = false
}
