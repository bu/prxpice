import Foundation

struct VMInfo: Identifiable, Codable, Hashable {
    let vmid: Int
    let node: String
    let name: String
    let status: VMStatus
    let type: VMType
    let cpus: Int?
    let maxmem: Int64?
    let maxdisk: Int64?
    let uptime: Int?

    var id: String { "\(node)/\(type.rawValue)/\(vmid)" }

    enum VMStatus: String, Codable {
        case running
        case stopped
        case paused
        case unknown

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = VMStatus(rawValue: value) ?? .unknown
        }
    }

    enum VMType: String, Codable {
        case qemu
        case lxc
    }

    var supportsSpice: Bool {
        type == .qemu && status == .running
    }
}

struct VMListResponse: Codable {
    let data: [VMInfo]
}
