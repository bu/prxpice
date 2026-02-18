import Foundation

/// URL builders for the Proxmox VE REST API.
enum ProxmoxEndpoints {
    /// POST /api2/json/access/ticket - authenticate with username/password
    static func ticket(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api2/json/access/ticket")
    }

    /// GET /api2/json/nodes - list cluster nodes
    static func nodes(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes")
    }

    /// GET /api2/json/nodes/{node}/qemu - list QEMU VMs on a node
    static func qemuVMs(baseURL: URL, node: String) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/qemu")
    }

    /// GET /api2/json/nodes/{node}/lxc - list LXC containers on a node
    static func lxcContainers(baseURL: URL, node: String) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/lxc")
    }

    /// GET /api2/json/nodes/{node}/qemu/{vmid}/status/current - VM status
    static func vmStatus(baseURL: URL, node: String, vmid: Int) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/qemu/\(vmid)/status/current")
    }

    /// POST /api2/json/nodes/{node}/qemu/{vmid}/spiceproxy - get SPICE connection config
    static func spiceProxy(baseURL: URL, node: String, vmid: Int) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/qemu/\(vmid)/spiceproxy")
    }

    /// POST /api2/json/nodes/{node}/qemu/{vmid}/status/start - start VM
    static func startVM(baseURL: URL, node: String, vmid: Int) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/qemu/\(vmid)/status/start")
    }

    /// POST /api2/json/nodes/{node}/qemu/{vmid}/status/stop - stop VM
    static func stopVM(baseURL: URL, node: String, vmid: Int) -> URL {
        baseURL.appendingPathComponent("api2/json/nodes/\(node)/qemu/\(vmid)/status/stop")
    }
}
