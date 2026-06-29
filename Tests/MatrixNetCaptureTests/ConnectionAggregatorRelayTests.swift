import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

/// The proxy engine's own upstream "relay" leg (e.g. LoonTunnelProvider → node)
/// carries other apps' traffic. While capturing, the apps' real bytes are read
/// from the tunnel interface, so counting the relay leg too would double-represent
/// the same traffic in the per-app aggregate — exclude it. Without capture it is
/// the ONLY signal (NStat reports 0 for the tunneled app sockets), so keep it.
@Suite("ConnectionAggregator proxy relay dedup")
struct ConnectionAggregatorRelayTests {
    private func conn(_ name: String, pid: Int32, srcPort: UInt16, dst: String, dstPort: UInt16) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("198.19.0.1")), port: srcPort)
        let destination = try Endpoint(address: #require(IPAddress(dst)), port: dstPort)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid, displayName: name),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("the proxy relay leg is excluded from packet-derived per-app totals")
    func relayExcludedFromPacketTotals() async throws {
        let aggregator = ConnectionAggregator()
        let app = try conn("Safari", pid: 1, srcPort: 52750, dst: "198.0.0.60", dstPort: 443)
        let relay = try conn("LoonTunnelProvider", pid: 2, srcPort: 50002, dst: "101.226.100.232", dstPort: 7978)
        await aggregator.apply(.added(app))
        await aggregator.apply(.added(relay))
        await aggregator.attributePackets([
            .init(flowKey: app.fiveTuple.flowKey, pid: 1, inbound: false, bytes: 1000),
            .init(flowKey: relay.fiveTuple.flowKey, pid: 2, inbound: false, bytes: 1000)
        ])
        let traffic = await aggregator.appTraffic()
        #expect(traffic.contains { $0.app.displayName == "Safari" })
        #expect(!traffic.contains { $0.app.displayName == "LoonTunnelProvider" })
    }

    @Test("without packet capture the relay leg is kept (it is the only NStat signal)")
    func relayKeptInNStatOnly() async throws {
        let aggregator = ConnectionAggregator()
        let relay = try conn("LoonTunnelProvider", pid: 2, srcPort: 50002, dst: "101.226.100.232", dstPort: 7978)
        await aggregator.apply(.added(relay))
        await aggregator.apply(.counts(
            id: relay.id,
            ConnectionCounts(
                bytesIn: 5000,
                bytesOut: 0,
                packetsIn: 0,
                packetsOut: 0,
                timestamp: Date(timeIntervalSince1970: 5)
            )
        ))
        let traffic = await aggregator.appTraffic()
        #expect(traffic.contains { $0.app.displayName == "LoonTunnelProvider" })
    }
}
