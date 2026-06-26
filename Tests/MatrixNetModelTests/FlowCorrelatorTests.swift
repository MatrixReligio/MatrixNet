import Foundation
import Testing
@testable import MatrixNetModel

@Suite("FlowCorrelator")
struct FlowCorrelatorTests {
    private func endpoint(_ ip: String, _ port: UInt16) throws -> Endpoint {
        try Endpoint(address: #require(IPAddress(ip)), port: port)
    }

    private func makeConnection(
        _ localPort: UInt16,
        pid: Int32 = 501,
        remote: String = "1.1.1.1"
    ) throws -> Connection {
        let tuple = try FiveTuple(
            proto: .tcp,
            source: endpoint("192.168.1.5", localPort),
            destination: endpoint(remote, 443)
        )
        return Connection(fiveTuple: tuple, app: AppIdentity(pid: pid), startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("registers a connection and finds it by flow key in either direction")
    func registerAndLookup() async throws {
        let correlator = FlowCorrelator()
        let connection = try makeConnection(50000)
        await correlator.register(connection)

        let forward = await correlator.connection(for: connection.fiveTuple.flowKey)
        #expect(forward?.id == connection.id)

        // A packet seen in the reverse direction must resolve to the same connection.
        let reversed = try FiveTuple(
            proto: .tcp,
            source: endpoint("1.1.1.1", 443),
            destination: endpoint("192.168.1.5", 50000)
        )
        let backward = await correlator.connectionID(forPacketFlow: reversed.flowKey, pid: nil)
        #expect(backward == connection.id)
    }

    @Test("falls back to PID when no flow key matches")
    func pidFallback() async throws {
        let correlator = FlowCorrelator()
        let connection = try makeConnection(50001, pid: 999)
        await correlator.register(connection)

        let unrelated = try FiveTuple(
            proto: .udp,
            source: endpoint("10.0.0.9", 1234),
            destination: endpoint("8.8.8.8", 53)
        )
        let resolved = await correlator.connectionID(forPacketFlow: unrelated.flowKey, pid: 999)
        #expect(resolved == connection.id)
    }

    @Test("returns nil when neither flow key nor pid matches")
    func noMatch() async throws {
        let correlator = FlowCorrelator()
        let unrelated = try FiveTuple(
            proto: .udp,
            source: endpoint("10.0.0.9", 1234),
            destination: endpoint("8.8.8.8", 53)
        )
        let resolved = await correlator.connectionID(forPacketFlow: unrelated.flowKey, pid: 4242)
        #expect(resolved == nil)
    }

    @Test("removing a connection drops its flow-key entry")
    func removeDropsEntry() async throws {
        let correlator = FlowCorrelator()
        let connection = try makeConnection(50002)
        await correlator.register(connection)
        await correlator.remove(connectionID: connection.id)
        let found = await correlator.connection(for: connection.fiveTuple.flowKey)
        #expect(found == nil)
        #expect(await correlator.allConnections.isEmpty)
    }

    @Test("a newer connection takes over a reused flow key")
    func portReuseTakeover() async throws {
        let correlator = FlowCorrelator()
        let first = try makeConnection(50003, remote: "1.1.1.1")
        let second = try makeConnection(50003, remote: "1.1.1.1")
        await correlator.register(first)
        await correlator.register(second)
        let found = await correlator.connection(for: first.fiveTuple.flowKey)
        #expect(found?.id == second.id)
    }

    @Test("records and resolves DNS hostnames")
    func hostnameMapping() async throws {
        let correlator = FlowCorrelator()
        let ip = try #require(IPAddress("93.184.216.34"))
        await correlator.recordHostname("example.com", for: ip)
        #expect(await correlator.hostname(for: ip) == "example.com")
        let otherIP = try #require(IPAddress("1.2.3.4"))
        #expect(await correlator.hostname(for: otherIP) == nil)
    }

    @Test("survives concurrent registration and lookup without losing connections")
    func concurrentStress() async {
        let correlator = FlowCorrelator()
        let count = 2000

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                group.addTask {
                    // Distinct local ports → distinct flow keys.
                    if let connection = try? makeConnection(UInt16(10000 + index), pid: Int32(index)) {
                        await correlator.register(connection)
                    }
                }
            }
        }

        let all = await correlator.allConnections
        #expect(all.count == count)

        // Every registered connection is resolvable by its PID concurrently.
        let resolvedCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for index in 0 ..< count {
                group.addTask {
                    await correlator.connectionID(
                        forPacketFlow: FlowKey(
                            proto: .other(254),
                            low: Endpoint(address: .v4(0), port: 0),
                            high: Endpoint(address: .v4(0), port: 0)
                        ),
                        pid: Int32(index)
                    ) != nil
                }
            }
            var total = 0
            for await matched in group where matched {
                total += 1
            }
            return total
        }
        #expect(resolvedCount == count)
    }
}
