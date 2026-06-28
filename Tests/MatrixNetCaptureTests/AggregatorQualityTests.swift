import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator quality")
struct AggregatorQualityTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("handshake segments produce a per-app quality snapshot")
    func handshake() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.apply(.added(conn))
        let key = conn.fiveTuple.flowKey
        let syn = TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0)
        let synAck = TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0)
        await aggregator.recordTCP(syn, timestampMicros: 1_000_000, inbound: false, flowKey: key, pid: 501)
        await aggregator.recordTCP(synAck, timestampMicros: 1_030_000, inbound: true, flowKey: key, pid: 501)
        let snapshot = await aggregator.qualitySnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.app == conn.app.displayName)
        #expect(snapshot.first?.quality.handshakeRTTms == 30.0)
    }

    @Test("a segment for an unknown flow is dropped")
    func unknownFlow() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        let syn = TCPSegment(flags: .syn, sequence: 1, acknowledgement: 0, payloadLength: 0)
        await aggregator.recordTCP(syn, timestampMicros: 0, inbound: false, flowKey: conn.fiveTuple.flowKey, pid: 501)
        #expect(await aggregator.qualitySnapshot().isEmpty)
    }
}
