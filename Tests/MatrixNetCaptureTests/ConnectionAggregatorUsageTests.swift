import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator usage snapshot")
struct ConnectionAggregatorUsageTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("usage accrues from NStat counts even without packet capture")
    func nstatUsageWithoutPackets() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50050)
        await aggregator.apply(.added(connection)) // baseline
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
        let snapshot = await aggregator.usageSnapshot()
        #expect(snapshot.contains { flow in
            flow.address.description == "1.1.1.1" && flow.bytesIn == 900 && flow.bytesOut == 100
        })
    }

    @Test("packet bytes accumulate per app+address and survive connection close")
    func survivesClose() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50040, pid: 9)
        await aggregator.apply(.added(connection))
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(
                flowKey: connection.fiveTuple.flowKey, pid: 9, inbound: true, bytes: 500
            ),
            ConnectionAggregator.PacketAttribution(
                flowKey: connection.fiveTuple.flowKey, pid: 9, inbound: false, bytes: 100
            )
        ])
        await aggregator.apply(.removed(connection.id))
        let snapshot = await aggregator.usageSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.bytesIn == 500)
        #expect(snapshot.first?.bytesOut == 100)
        #expect(snapshot.first?.address.description == "1.1.1.1")
    }

    @Test("reset clears usage")
    func resetClears() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50041, pid: 9)
        await aggregator.apply(.added(connection))
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(
                flowKey: connection.fiveTuple.flowKey, pid: 9, inbound: true, bytes: 9
            )
        ])
        await aggregator.reset()
        #expect(await aggregator.usageSnapshot().isEmpty)
    }
}
