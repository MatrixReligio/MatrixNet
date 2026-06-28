import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator fingerprints")
struct AggregatorFingerprintTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("a recorded fingerprint is attributed to its app and de-duplicated")
    func record() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.apply(.added(conn))
        let key = conn.fiveTuple.flowKey
        await aggregator.recordFingerprint("t13d1516h2_aaaa_bbbb", flowKey: key, pid: 501)
        await aggregator.recordFingerprint("t13d1516h2_aaaa_bbbb", flowKey: key, pid: 501)
        let snapshot = await aggregator.fingerprintSnapshot()
        #expect(snapshot == [AppFingerprintObservation(app: conn.app.displayName, ja4: "t13d1516h2_aaaa_bbbb")])
    }

    @Test("a fingerprint for an unknown flow is dropped")
    func unknownFlow() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        // Never added → no connection to attribute the fingerprint to.
        await aggregator.recordFingerprint("t13d_x_y", flowKey: conn.fiveTuple.flowKey, pid: 501)
        let snapshot = await aggregator.fingerprintSnapshot()
        #expect(snapshot.isEmpty)
    }
}
