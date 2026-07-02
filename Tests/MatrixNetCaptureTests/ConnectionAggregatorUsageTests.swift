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

    @Test("snapshot keeps NStat-only flows alongside packet flows")
    func mergesNStatAndPacket() async throws {
        let aggregator = ConnectionAggregator()
        // App A: NStat-only usage (no captured packets), destination 1.1.1.1.
        let connA = try connection(50050, pid: 501)
        await aggregator.apply(.added(connA))
        await aggregator.apply(.counts(
            id: connA.id,
            ConnectionCounts(
                bytesIn: 900,
                bytesOut: 100,
                packetsIn: 6,
                packetsOut: 4,
                timestamp: Date(timeIntervalSince1970: 5)
            )
        ))
        // App B: packet-derived usage to a different destination.
        let bSource = try Endpoint(address: #require(IPAddress("192.168.1.6")), port: 50060)
        let bDest = try Endpoint(address: #require(IPAddress("8.8.8.8")), port: 443)
        let connB = Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: bSource, destination: bDest),
            app: AppIdentity(pid: 9),
            startedAt: Date(timeIntervalSince1970: 0)
        )
        await aggregator.apply(.added(connB))
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(flowKey: connB.fiveTuple.flowKey, pid: 9, inbound: true, bytes: 500)
        ])

        // Packet data exists, but the NStat-only flow must NOT be shadowed away.
        let usage = await aggregator.usageSnapshot()
        #expect(usage.contains { $0.address.description == "1.1.1.1" && $0.bytesIn == 900 })
        #expect(usage.contains { $0.address.description == "8.8.8.8" && $0.bytesIn == 500 })

        // Same for the per-app traffic snapshot.
        let apps = await aggregator.appTraffic()
        #expect(apps.contains { $0.bytesIn == 900 })
        #expect(apps.contains { $0.bytesIn == 500 })
    }

    @Test("a packet with no flow-key match is not misattributed to a same-PID connection")
    func noPidMisattribution() async throws {
        let aggregator = ConnectionAggregator()
        // A live connection for pid 501 to 1.1.1.1.
        let connA = try connection(50050, pid: 501)
        await aggregator.apply(.added(connA))
        // A packet for the SAME pid but a DIFFERENT, unregistered flow (8.8.8.8).
        let bSource = try Endpoint(address: #require(IPAddress("192.168.1.6")), port: 50060)
        let bDest = try Endpoint(address: #require(IPAddress("8.8.8.8")), port: 443)
        let bKey = FiveTuple(proto: .tcp, source: bSource, destination: bDest).flowKey
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(flowKey: bKey, pid: 501, inbound: true, bytes: 500)
        ])
        // The 500 bytes must NOT be attributed to the 1.1.1.1 connection via PID.
        let usage = await aggregator.usageSnapshot()
        #expect(!usage.contains { $0.address.description == "1.1.1.1" })
    }

    @Test("ending a capture session falls back to the live NStat figures instead of freezing")
    func endCaptureSessionUnfreezes() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50070, pid: 9)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(
                bytesIn: 900,
                bytesOut: 0,
                packetsIn: 6,
                packetsOut: 4,
                timestamp: Date(timeIntervalSince1970: 5)
            )
        ))
        // While capturing, the packet-derived overlay wins for covered keys.
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(
                flowKey: connection.fiveTuple.flowKey, pid: 9, inbound: true, bytes: 60
            )
        ])
        #expect(await aggregator.usageSnapshot().first?.bytesIn == 60)
        #expect(await aggregator.appTraffic().first?.bytesIn == 60)

        // Capture stops: the overlay must clear so the (still-growing) NStat
        // figures come back — not freeze at the last packet totals forever.
        await aggregator.endCaptureSession()
        #expect(await aggregator.usageSnapshot().first?.bytesIn == 900)
        #expect(await aggregator.appTraffic().first?.bytesIn == 900)
        #expect(await aggregator.snapshot().first?.bytesIn == 900)
    }

    @Test("usageSnapshotBySource exposes each source's raw totals")
    func snapshotBySource() async throws {
        let aggregator = ConnectionAggregator()
        let connection = try connection(50071, pid: 9)
        await aggregator.apply(.added(connection))
        await aggregator.apply(.counts(
            id: connection.id,
            ConnectionCounts(
                bytesIn: 900,
                bytesOut: 0,
                packetsIn: 6,
                packetsOut: 4,
                timestamp: Date(timeIntervalSince1970: 5)
            )
        ))
        await aggregator.attributePackets([
            ConnectionAggregator.PacketAttribution(
                flowKey: connection.fiveTuple.flowKey, pid: 9, inbound: true, bytes: 60
            )
        ])
        let sources = await aggregator.usageSnapshotBySource()
        #expect(sources.packet.first?.bytesIn == 60)
        #expect(sources.nstat.first?.bytesIn == 900)
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
