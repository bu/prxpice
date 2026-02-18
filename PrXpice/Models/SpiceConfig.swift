import Foundation

/// Parsed SPICE connection configuration from Proxmox virt-viewer format.
/// Example response from POST /api2/spiceconfig:
/// ```
/// [virt-viewer]
/// type=spice
/// host=192.168.1.100
/// port=61000
/// tls-port=61001
/// password=xxxx
/// ca=...
/// host-subject=...
/// ```
struct SpiceConfig {
    let host: String
    let port: Int
    let tlsPort: Int?
    let password: String
    let ca: String?
    let hostSubject: String?
    let proxy: String?
    let secureChannels: String?

    /// Parses a virt-viewer .ini-style config string
    static func parse(from configString: String) -> SpiceConfig? {
        var values: [String: String] = [:]
        for line in configString.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let host = values["host"],
              let portStr = values["port"], let port = Int(portStr),
              let password = values["password"]
        else {
            return nil
        }

        return SpiceConfig(
            host: host,
            port: port,
            tlsPort: values["tls-port"].flatMap(Int.init),
            password: password,
            ca: values["ca"],
            hostSubject: values["host-subject"],
            proxy: values["proxy"],
            secureChannels: values["secure-channels"]
        )
    }
}
