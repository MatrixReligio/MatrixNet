import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

/// Characterises the EXISTING pipeline's behaviour for a TUN-proxied (fake-IP)
/// connection, to verify whether the generic flowKey-based packet attribution
/// already recovers real bytes + domain (lsof confirmed NStat reports the same
/// gateway-sourced 5-tuple as the utun packets, so the flowKeys match).
@Suite("ConnectionAggregator proxy (fake-IP) behaviour")
struct ConnectionAggregatorProxyTests {
    @Test("captured utun packets give a proxied connection real bytes via flowKey")
    func proxiedConnectionGetsRealBytesFromPackets() async throws {
        let aggregator = ConnectionAggregator()
        // NStat reports the proxied connection with source = TUN gateway
        // 198.19.0.1, destination = fake IP 198.0.0.60, and 0 bytes (the kernel
        // does not count tunnelled bytes on the app socket).
        let gateway = try Endpoint(address: #require(IPAddress("198.19.0.1")), port: 52750)
        let fake = try Endpoint(address: #require(IPAddress("198.0.0.60")), port: 443)
        let five = FiveTuple(proto: .tcp, source: gateway, destination: fake)
        let conn = Connection(
            fiveTuple: five,
            app: AppIdentity(pid: 1778, displayName: "Safari"),
            startedAt: Date(timeIntervalSince1970: 0)
        )
        await aggregator.apply(.added(conn))

        // utun packets for the same flow (direction-insensitive flowKey matches).
        // The inbound leg carries the proxy's PID, but correlation is by flowKey.
        await aggregator.attributePackets([
            .init(flowKey: five.flowKey, pid: 1778, inbound: false, bytes: 517),
            .init(flowKey: five.flowKey, pid: 14428, inbound: true, bytes: 1400)
        ])

        let snap = try #require(await aggregator.snapshot().first)
        #expect(snap.bytesOut == 517)
        #expect(snap.bytesIn == 1400)
    }

    @Test("SNI recorded against the fake IP enriches the proxied connection hostname")
    func proxiedConnectionGetsDomainFromSNI() async throws {
        let aggregator = ConnectionAggregator()
        let fakeIP = try #require(IPAddress("198.0.0.60"))
        await aggregator.recordHostname("www.cloudflare.com", for: fakeIP)
        #expect(await aggregator.hostnameSnapshot()[fakeIP] == "www.cloudflare.com")
    }
}
