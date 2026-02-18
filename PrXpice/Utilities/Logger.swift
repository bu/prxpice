import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.prxpice"

    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let spice = os.Logger(subsystem: subsystem, category: "spice")
    static let rendering = os.Logger(subsystem: subsystem, category: "rendering")
    static let network = os.Logger(subsystem: subsystem, category: "network")
    static let input = os.Logger(subsystem: subsystem, category: "input")
}
