import Foundation
import Testing
@testable import MatrixNetModel

@Suite("OverviewStats")
struct OverviewStatsTests {
    private func connection(
        pid: Int32,
        dest: String,
        proto: TransportProtocol = .tcp,
        localPort: UInt16 = 51000,
        remotePort: UInt16 = 443,
        bytes: UInt64 = 100,
        state: ConnectionState = .active
    ) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.10")), port: localPort)
        let destination = try Endpoint(address: #require(IPAddress(dest)), port: remotePort)
        return Connection(
            fiveTuple: FiveTuple(proto: proto, source: source, destination: destination),
            app: AppIdentity(pid: pid, displayName: "App\(pid)"),
            bytesIn: bytes,
            startedAt: Date(timeIntervalSince1970: 1000),
            state: state
        )
    }

    @Test("active app count is the number of distinct processes with active flows")
    func activeApps() throws {
        let connections = try [
            connection(pid: 1, dest: "93.184.216.34"),
            connection(pid: 1, dest: "1.1.1.1"),
            connection(pid: 2, dest: "8.8.8.8"),
            connection(pid: 3, dest: "9.9.9.9", state: .closed)
        ]
        #expect(OverviewStats.activeAppCount(connections) == 2)
    }

    @Test("countries reached counts distinct known countries among active flows")
    func countries() throws {
        let connections = try [
            connection(pid: 1, dest: "93.184.216.34"),
            connection(pid: 2, dest: "1.1.1.1"),
            connection(pid: 3, dest: "8.8.8.8")
        ]
        let map = ["93.184.216.34": "US", "1.1.1.1": "US", "8.8.8.8": "JP"]
        let count = OverviewStats.countriesReached(connections) { map[$0.description] }
        #expect(count == 2)
    }

    @Test("proxy share is the fraction of active flows routed through a proxy")
    func proxyShare() throws {
        let connections = try [
            connection(pid: 1, dest: "10.0.0.1"),
            connection(pid: 2, dest: "10.0.0.2"),
            connection(pid: 3, dest: "8.8.8.8"),
            connection(pid: 4, dest: "9.9.9.9", state: .closed)
        ]
        let proxied: Set = ["10.0.0.1", "10.0.0.2"]
        let share = OverviewStats.proxyShare(connections) { proxied.contains($0.address.description) }
        #expect(abs(share - 2.0 / 3.0) < 0.0001)
    }

    @Test("protocol mix classifies by service port and sums to one")
    func protocolMix() throws {
        let connections = try [
            connection(pid: 1, dest: "93.184.216.34", proto: .tcp, remotePort: 443),
            connection(pid: 2, dest: "1.1.1.1", proto: .tcp, remotePort: 443),
            connection(pid: 3, dest: "8.8.8.8", proto: .udp, remotePort: 53),
            connection(pid: 4, dest: "9.9.9.9", proto: .udp, remotePort: 443)
        ]
        let mix = OverviewStats.protocolMix(connections)
        let top = try #require(mix.first)
        #expect(top.label == "TLS") // most common
        #expect(abs(top.share - 0.5) < 0.0001)
        #expect(abs(mix.reduce(0) { $0 + $1.share } - 1.0) < 0.0001)
        #expect(Set(mix.map(\.label)) == ["TLS", "DNS", "QUIC"])
    }

    @Test("destination countries rank by active connection count")
    func destinations() throws {
        let connections = try [
            connection(pid: 1, dest: "93.184.216.34"),
            connection(pid: 2, dest: "1.1.1.1"),
            connection(pid: 3, dest: "8.8.8.8"),
            connection(pid: 4, dest: "9.9.9.9", state: .closed)
        ]
        let map = ["93.184.216.34": "US", "1.1.1.1": "US", "8.8.8.8": "JP", "9.9.9.9": "JP"]
        let ranked = OverviewStats.destinationCountries(connections) { map[$0.description] }
        #expect(ranked.map(\.country) == ["US", "JP"]) // US 2 active > JP 1 active
        #expect(ranked.first?.connections == 2)
    }
}
