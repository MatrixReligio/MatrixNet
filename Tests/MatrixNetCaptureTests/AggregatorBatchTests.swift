import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

/// The packet pipeline hands the aggregator each batch's hostnames, fingerprints
/// and TCP segments in one actor hop apiece (instead of one `await` per item), so
/// a high-rate capture doesn't thrash the shared actor. These verify the batch
/// entrypoints attribute exactly as the per-item calls do.
@Suite("ConnectionAggregator batch attribution")
struct AggregatorBatchTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("recordTCPSegments batch produces the same quality snapshot as per-item calls")
    func tcpBatch() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.apply(.added(conn))
        let key = conn.fiveTuple.flowKey
        let syn = TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0)
        let synAck = TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0)
        await aggregator.recordTCPSegments([
            ConnectionAggregator.TCPSegmentEntry(
                segment: syn, timestampMicros: 1_000_000, inbound: false, flowKey: key, pid: 501
            ),
            ConnectionAggregator.TCPSegmentEntry(
                segment: synAck, timestampMicros: 1_030_000, inbound: true, flowKey: key, pid: 501
            )
        ])
        let snapshot = await aggregator.qualitySnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.app == conn.app.displayName)
        #expect(snapshot.first?.quality.handshakeRTTms == 30.0)
    }

    @Test("recordFingerprints batch attributes each JA4 to its app")
    func fingerprintBatch() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.apply(.added(conn))
        let key = conn.fiveTuple.flowKey
        await aggregator.recordFingerprints([
            ConnectionAggregator.FingerprintEntry(
                ja4: "t13d1516h2_8daaf6152771_b186095e22b6", flowKey: key, pid: 501
            )
        ])
        let snapshot = await aggregator.fingerprintSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.app == conn.app.displayName)
    }

    @Test("recordHostnames batch records every observed name")
    func hostnameBatch() async throws {
        let aggregator = ConnectionAggregator()
        let one = try #require(IPAddress("1.1.1.1"))
        let two = try #require(IPAddress("8.8.8.8"))
        await aggregator.recordHostnames([
            ConnectionAggregator.HostnameEntry(name: "one.example", ip: one),
            ConnectionAggregator.HostnameEntry(name: "two.example", ip: two)
        ])
        let snapshot = await aggregator.hostnameSnapshot()
        #expect(snapshot[one] == "one.example")
        #expect(snapshot[two] == "two.example")
    }
}
