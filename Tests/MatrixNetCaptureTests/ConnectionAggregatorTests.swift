import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator")
struct ConnectionAggregatorTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("added connections appear in the snapshot")
    func addedAppears() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50000)
        await aggregator.apply(.added(connection))
        let snapshot = await aggregator.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.id == connection.id)
    }

    @Test("counts events update cumulative byte totals")
    func countsUpdate() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50001)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(
                bytesIn: 900,
                bytesOut: 100,
                packetsIn: 6,
                packetsOut: 4,
                timestamp: Date(timeIntervalSince1970: 5)
            )
        ))
        let updated = try #require(await aggregator.snapshot().first)
        #expect(updated.bytesIn == 900)
        #expect(updated.bytesOut == 100)
        #expect(updated.totalBytes == 1000)
    }

    @Test("counts for an unknown connection are ignored")
    func countsUnknownIgnored() async {
        let aggregator = ConnectionAggregator()
        await aggregator.apply(.counts(
            id: UUID(),
            ConnectionCounts(bytesIn: 1, bytesOut: 1, packetsIn: 1, packetsOut: 1, timestamp: Date())
        ))
        #expect(await aggregator.snapshot().isEmpty)
    }

    @Test("removed connections drop out of the live snapshot")
    func removedDropsConnection() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50002)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.removed(connection.id))
        #expect(await aggregator.snapshot().isEmpty)
    }

    @Test("re-describing a connection keeps monotonic counters")
    func reDescribeKeepsCounters() async throws {
        let aggregator = ConnectionAggregator()
        var connection = try connection(50005)
        connection.bytesIn = 5000
        await aggregator.apply(.added(connection))
        // A later description arrives with stale (smaller) counters.
        var stale = connection
        stale.bytesIn = 10
        await aggregator.apply(.added(stale))
        #expect(await aggregator.snapshot().first?.bytesIn == 5000)
    }

    @Test("session totals accumulate growth across counts updates")
    func sessionAccumulates() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50010)
        await aggregator.apply(.added(connection)) // baseline 0/0
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 300, bytesOut: 100, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 500, bytesOut: 100, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        let totals = await aggregator.sessionTotals()
        #expect(totals.bytesIn == 500)
        #expect(totals.bytesOut == 100)
    }

    @Test("session totals survive connection removal")
    func sessionSurvivesRemoval() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50011)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 4096, bytesOut: 2048, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        await aggregator.apply(.removed(connection.id))
        // The live snapshot drops it, but session totals must persist.
        #expect(await aggregator.snapshot().isEmpty)
        let totals = await aggregator.sessionTotals()
        #expect(totals.bytesIn == 4096)
        #expect(totals.bytesOut == 2048)
    }

    @Test("a connection first seen with bytes sets a baseline (no double counting)")
    func sessionBaseline() async throws {
        let aggregator = ConnectionAggregator()
        var connection = try connection(50012)
        connection.bytesIn = 1000 // already had lifetime traffic before first sight
        connection.bytesOut = 500
        await aggregator.apply(.added(connection))
        // First sight establishes a baseline; only subsequent growth counts.
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 1200, bytesOut: 500, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        let totals = await aggregator.sessionTotals()
        #expect(totals.bytesIn == 200) // 1200 - 1000 baseline
        #expect(totals.bytesOut == 0)
    }

    @Test("reset clears connections and session totals for a fresh session")
    func resetClears() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50013)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 7000, bytesOut: 3000, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        await aggregator.reset()
        #expect(await aggregator.snapshot().isEmpty)
        let totals = await aggregator.sessionTotals()
        #expect(totals.bytesIn == 0)
        #expect(totals.bytesOut == 0)
        #expect(await aggregator.appTraffic().isEmpty)
    }

    @Test("per-app traffic accumulates the growth of a connection's counters")
    func appTrafficAccumulates() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50020, pid: 1)
        await aggregator.apply(.added(connection)) // baseline 0/0
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(bytesIn: 300, bytesOut: 100, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        let traffic = await aggregator.appTraffic()
        #expect(traffic.count == 1)
        #expect(traffic.first?.bytesIn == 300)
        #expect(traffic.first?.bytesOut == 100)
        #expect(traffic.first?.bytes == 400)
        #expect(traffic.first?.app.displayName == "PID 1")
    }

    @Test("per-app traffic sums across an app's connections and survives removal")
    func appTrafficSumsAndSurvives() async throws {
        let aggregator = ConnectionAggregator()
        // Two connections owned by the same process (same display name).
        let first = try connection(50021, pid: 7)
        let second = try connection(50022, pid: 7)
        await aggregator.apply(.added(first))
        await aggregator.apply(.added(second))
        await aggregator.apply(.counts(
            id: first.id,
            ConnectionCounts(bytesIn: 1000, bytesOut: 0, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        await aggregator.apply(.counts(
            id: second.id,
            ConnectionCounts(bytesIn: 500, bytesOut: 0, packetsIn: 0, packetsOut: 0, timestamp: Date())
        ))
        // Closing the first flow must not lose its contribution to the app total.
        await aggregator.apply(.removed(first.id))
        let traffic = await aggregator.appTraffic()
        #expect(traffic.count == 1)
        #expect(traffic.first?.app.displayName == "PID 7")
        #expect(traffic.first?.bytesIn == 1500)
    }

    @Test("packet correlation resolves registered connections by flow key")
    func packetCorrelation() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50003)
        await aggregator.apply(.added(connection))
        let resolved = await aggregator.connectionID(forPacketFlow: connection.fiveTuple.flowKey, pid: nil)
        #expect(resolved == connection.id)
    }

    @Test("stays consistent under concurrent connection events and packet queries")
    func dualSourceConcurrency() async throws {
        let aggregator = ConnectionAggregator()
        let count = 1000
        let connections = try (0 ..< count).map { try connection(UInt16(20000 + $0), pid: Int32($0)) }

        await withTaskGroup(of: Void.self) { group in
            // Source 1: connection events.
            for connection in connections {
                group.addTask { await aggregator.apply(.added(connection)) }
            }
            // Source 2: concurrent packet attribution queries by PID. The flow
            // key never matches a registered connection, forcing the PID path.
            let unmatchedKey = FiveTuple(
                proto: .other(254),
                source: Endpoint(address: .v4(0), port: 0),
                destination: Endpoint(address: .v4(0), port: 1)
            ).flowKey
            for index in 0 ..< count {
                group.addTask {
                    _ = await aggregator.connectionID(forPacketFlow: unmatchedKey, pid: Int32(index))
                }
            }
        }

        #expect(await aggregator.snapshot().count == count)
    }
}
