import Foundation
import UIKit

/// Installs uncaught exception and signal handlers that write a crash log
/// to the app's Documents directory before the process dies.
///
/// Log files are named "crash_<timestamp>.txt" and are visible in the
/// iOS Files app under "On My iPad → PrXpice".
///
/// Call `CrashLogger.install()` once at app launch.
enum CrashLogger {

    static func install() {
        NSSetUncaughtExceptionHandler(exceptionHandler)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
        log("App launched — crash logger installed (v\(appVersion))")
    }

    // MARK: - Handlers

    private static let exceptionHandler: @convention(c) (NSException) -> Void = { exception in
        let lines: [String] = [
            "=== UNCAUGHT EXCEPTION ===",
            "Name   : \(exception.name.rawValue)",
            "Reason : \(exception.reason ?? "nil")",
            "UserInfo: \(exception.userInfo ?? [:])",
            "",
            "Call stack:",
        ] + exception.callStackSymbols

        write(lines.joined(separator: "\n"))
    }

    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        let name: String
        switch sig {
        case SIGSEGV: name = "SIGSEGV (segmentation fault)"
        case SIGABRT: name = "SIGABRT (abort)"
        case SIGBUS:  name = "SIGBUS (bus error)"
        case SIGILL:  name = "SIGILL (illegal instruction)"
        case SIGFPE:  name = "SIGFPE (floating point exception)"
        case SIGTRAP: name = "SIGTRAP (trap)"
        default:      name = "SIG\(sig)"
        }

        let lines: [String] = [
            "=== FATAL SIGNAL ===",
            "Signal: \(name)",
            "",
            "Thread call stack (limited):",
        ] + Thread.callStackSymbols

        write(lines.joined(separator: "\n"))

        // Re-raise so the OS records a proper crash report too
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - Persistent log

    /// Appends a message to today's persistent log file in Documents.
    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL(for: Date())
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Returns all log file URLs sorted newest first.
    static func allLogFiles() -> [URL] {
        let dir = documentsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("prxpice_log_") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
    }

    /// Deletes log files older than `days` days.
    static func pruneOldLogs(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for url in allLogFiles() {
            guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func write(_ body: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let full = "[\(ts)]\n\(body)\n\n--- Device: \(deviceInfo()) ---\n"
        guard let data = full.data(using: .utf8) else { return }

        // Use a crash-specific file so it stands out
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "prxpice_crash_\(formatter.string(from: Date())).txt"
        let url = documentsDirectory().appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)

        // Also append to today's running log
        log(body)
    }

    private static func logFileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "prxpice_log_\(formatter.string(from: date)).txt"
        return documentsDirectory().appendingPathComponent(name)
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static func deviceInfo() -> String {
        let device = UIDevice.current
        return "\(device.model) iOS \(device.systemVersion)"
    }
}
