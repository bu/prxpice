import Foundation

struct VMInfo: Identifiable, Codable, Hashable {
    let vmid: Int
    var node: String  // injected after decode — not present in per-node API responses
    let name: String
    let status: VMStatus
    let type: VMType
    let cpus: Int?
    let maxmem: Int64?
    let maxdisk: Int64?
    let uptime: Int?

    var id: String { "\(node)/\(type.rawValue)/\(vmid)" }

    enum CodingKeys: String, CodingKey {
        case vmid, name, status, type, cpus, maxmem, maxdisk, uptime
        // `node` is excluded — set by the caller after decoding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmid   = try c.decode(Int.self, forKey: .vmid)
        name   = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decode(VMStatus.self, forKey: .status)
        type   = try c.decodeIfPresent(VMType.self, forKey: .type) ?? .qemu
        cpus   = try c.decodeIfPresent(Int.self, forKey: .cpus)
        maxmem = try c.decodeIfPresent(Int64.self, forKey: .maxmem)
        maxdisk = try c.decodeIfPresent(Int64.self, forKey: .maxdisk)
        uptime = try c.decodeIfPresent(Int.self, forKey: .uptime)
        node   = ""  // populated by ProxmoxAPIClient after decode
    }

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

    // Set after fetching VM config — true if vga is qxl/qxl2/qxl4
    var hasSpiceDisplay: Bool = false

    var supportsSpice: Bool {
        type == .qemu && status == .running && hasSpiceDisplay
    }
}

struct VMListResponse: Codable {
    let data: [VMInfo]
}
