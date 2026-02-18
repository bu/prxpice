import XCTest
@testable import PrXpice

final class SpiceConfigTests: XCTestCase {

    func testParseValidConfig() {
        let configString = """
        [virt-viewer]
        type=spice
        host=192.168.1.100
        port=61000
        tls-port=61001
        password=abc123
        ca=-----BEGIN CERTIFICATE-----\nMIID...\n-----END CERTIFICATE-----
        host-subject=O=Proxmox,CN=pve.local
        """

        let config = SpiceConfig.parse(from: configString)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.host, "192.168.1.100")
        XCTAssertEqual(config?.port, 61000)
        XCTAssertEqual(config?.tlsPort, 61001)
        XCTAssertEqual(config?.password, "abc123")
        XCTAssertNotNil(config?.ca)
        XCTAssertEqual(config?.hostSubject, "O=Proxmox,CN=pve.local")
    }

    func testParseMinimalConfig() {
        let configString = """
        [virt-viewer]
        host=10.0.0.1
        port=5900
        password=secret
        """

        let config = SpiceConfig.parse(from: configString)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.host, "10.0.0.1")
        XCTAssertEqual(config?.port, 5900)
        XCTAssertNil(config?.tlsPort)
        XCTAssertEqual(config?.password, "secret")
        XCTAssertNil(config?.ca)
    }

    func testParseInvalidConfig() {
        let configString = """
        [virt-viewer]
        host=10.0.0.1
        """

        let config = SpiceConfig.parse(from: configString)
        XCTAssertNil(config, "Config without port and password should fail to parse")
    }

    func testParseEmptyString() {
        let config = SpiceConfig.parse(from: "")
        XCTAssertNil(config)
    }

    func testParseWithExtraWhitespace() {
        let configString = """
        [virt-viewer]
        host = 192.168.1.50
        port = 5901
        password = mypass
        """

        let config = SpiceConfig.parse(from: configString)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.host, "192.168.1.50")
        XCTAssertEqual(config?.port, 5901)
    }
}

final class ServerConnectionTests: XCTestCase {

    func testDefaultValues() {
        let conn = ServerConnection()
        XCTAssertEqual(conn.port, 8006)
        XCTAssertEqual(conn.username, "root@pam")
        XCTAssertEqual(conn.authMethod, .password)
        XCTAssertNil(conn.lastConnected)
    }

    func testBaseURL() {
        let conn = ServerConnection(hostname: "pve.example.com", port: 8006)
        XCTAssertEqual(conn.baseURL.absoluteString, "https://pve.example.com:8006")
    }

    func testCodable() throws {
        let original = ServerConnection(
            name: "Test Server",
            hostname: "192.168.1.1",
            port: 8006,
            authMethod: .apiToken,
            username: "admin@pam",
            tokenID: "admin@pam!mytoken"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConnection.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.hostname, original.hostname)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.authMethod, .apiToken)
        XCTAssertEqual(decoded.tokenID, original.tokenID)
    }
}

final class VMInfoTests: XCTestCase {

    func testSupportsSpice() {
        let running = VMInfo(
            vmid: 100, node: "pve", name: "test",
            status: .running, type: .qemu,
            cpus: 4, maxmem: 8_589_934_592, maxdisk: nil, uptime: 3600
        )
        XCTAssertTrue(running.supportsSpice)

        let stopped = VMInfo(
            vmid: 101, node: "pve", name: "test2",
            status: .stopped, type: .qemu,
            cpus: 2, maxmem: nil, maxdisk: nil, uptime: nil
        )
        XCTAssertFalse(stopped.supportsSpice)

        let lxc = VMInfo(
            vmid: 200, node: "pve", name: "ct",
            status: .running, type: .lxc,
            cpus: 1, maxmem: nil, maxdisk: nil, uptime: 100
        )
        XCTAssertFalse(lxc.supportsSpice)
    }

    func testIdentifier() {
        let vm = VMInfo(
            vmid: 100, node: "node1", name: "myvm",
            status: .running, type: .qemu,
            cpus: nil, maxmem: nil, maxdisk: nil, uptime: nil
        )
        XCTAssertEqual(vm.id, "node1/qemu/100")
    }
}
