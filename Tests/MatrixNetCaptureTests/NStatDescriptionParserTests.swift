import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

private func sockaddrV4(_ ip: [UInt8], port: UInt16) -> Data {
    var bytes: [UInt8] = [0x10, 0x02, UInt8(port >> 8), UInt8(port & 0xFF)]
    bytes += ip
    bytes += [UInt8](repeating: 0, count: 8)
    return Data(bytes)
}

@Suite("NStatDescriptionParser")
struct NStatDescriptionParserTests {
    private let start = Date(timeIntervalSince1970: 1000)

    private func tcpDescription() -> [String: Any] {
        [
            "provider": "TCP",
            "localAddress": sockaddrV4([192, 168, 1, 5], port: 50000),
            "remoteAddress": sockaddrV4([93, 184, 216, 34], port: 443),
            "processID": 1234,
            "processName": "curl",
            "rxBytes": 5000,
            "txBytes": 1200
        ]
    }

    @Test("maps provider to transport protocol")
    func providerMapping() {
        #expect(NStatDescriptionParser.transportProtocol(from: "TCP") == .tcp)
        #expect(NStatDescriptionParser.transportProtocol(from: "UDP") == .udp)
        #expect(NStatDescriptionParser.transportProtocol(from: "wat") == nil)
    }

    @Test("maps TCPState to connection state", arguments: [
        ("Established", ConnectionState.active),
        ("SynSent", .active),
        ("Listen", .active),
        ("Closed", .closed),
        ("TimeWait", .closed),
        ("CloseWait", .closed)
    ])
    func mapsTCPState(_ tcpState: String, _ expected: ConnectionState) {
        var description = tcpDescription()
        description["TCPState"] = tcpState
        #expect(NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start)?.state == expected)
    }

    @Test("UDP flows are active regardless of TCP state field")
    func udpIsActive() {
        var description = tcpDescription()
        description["provider"] = "UDP"
        description["TCPState"] = nil
        #expect(NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start)?.state == .active)
    }

    @Test("builds a connection from a TCP description dictionary")
    func parsesTCPDescription() throws {
        let connection = try #require(
            NStatDescriptionParser.connection(from: tcpDescription(), id: UUID(), startedAt: start)
        )
        #expect(connection.fiveTuple.proto == .tcp)
        #expect(connection.fiveTuple.source.address == IPAddress("192.168.1.5"))
        #expect(connection.fiveTuple.source.port == 50000)
        #expect(connection.fiveTuple.destination.address == IPAddress("93.184.216.34"))
        #expect(connection.fiveTuple.destination.port == 443)
        #expect(connection.app.pid == 1234)
        #expect(connection.app.displayName == "curl")
        #expect(connection.bytesIn == 5000)
        #expect(connection.bytesOut == 1200)
    }

    @Test("drops an idle listening socket (remote port 0, no traffic)")
    func dropsIdleListener() {
        var description = tcpDescription()
        description["remoteAddress"] = sockaddrV4([0, 0, 0, 0], port: 0)
        description["rxBytes"] = 0
        description["txBytes"] = 0
        #expect(NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start) == nil)
    }

    @Test("keeps a remote-port-0 flow that has observed traffic")
    func keepsActivePortZeroFlow() throws {
        var description = tcpDescription()
        description["provider"] = "UDP"
        description["TCPState"] = nil
        description["remoteAddress"] = sockaddrV4([0, 0, 0, 0], port: 0)
        description["rxBytes"] = 86
        description["txBytes"] = 0
        let connection = try #require(
            NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start)
        )
        #expect(connection.bytesIn == 86)
        #expect(connection.fiveTuple.destination.port == 0)
    }

    @Test("returns nil when the protocol is missing")
    func missingProvider() {
        var description = tcpDescription()
        description["provider"] = nil
        #expect(NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start) == nil)
    }

    @Test("returns nil when an address is missing or malformed")
    func missingAddress() {
        var description = tcpDescription()
        description["remoteAddress"] = Data([0x00]) // malformed sockaddr
        #expect(NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start) == nil)
    }

    @Test("parses a counts dictionary into a ConnectionCounts snapshot")
    func parsesCounts() {
        let now = Date(timeIntervalSince1970: 42)
        let counts = NStatDescriptionParser.counts(
            from: ["rxBytes": 9000, "txBytes": 800, "rxPackets": 12, "txPackets": 7],
            at: now
        )
        #expect(counts.bytesIn == 9000)
        #expect(counts.bytesOut == 800)
        #expect(counts.packetsIn == 12)
        #expect(counts.packetsOut == 7)
        #expect(counts.timestamp == now)
    }

    @Test("counts dictionary with missing fields defaults to zero")
    func parsesCountsMissing() {
        let counts = NStatDescriptionParser.counts(from: [:], at: Date(timeIntervalSince1970: 0))
        #expect(counts.bytesIn == 0)
        #expect(counts.bytesOut == 0)
        #expect(counts.packetsIn == 0)
        #expect(counts.packetsOut == 0)
    }

    @Test("tolerates missing optional fields (counters default to zero)")
    func missingCounters() throws {
        var description = tcpDescription()
        description["rxBytes"] = nil
        description["txBytes"] = nil
        description["processName"] = nil
        let connection = try #require(
            NStatDescriptionParser.connection(from: description, id: UUID(), startedAt: start)
        )
        #expect(connection.bytesIn == 0)
        #expect(connection.bytesOut == 0)
        // Display name falls back to a PID placeholder.
        #expect(connection.app.displayName == "PID 1234")
    }
}
