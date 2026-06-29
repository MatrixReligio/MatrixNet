import Foundation
import Testing
@testable import MatrixNetModel

struct TunneledFlowStitchTests {
    private func address(_ string: String) throws -> IPAddress {
        try #require(IPAddress(string))
    }

    private func tuple(gateway: IPAddress, srcPort: UInt16, fake: IPAddress) -> FiveTuple {
        FiveTuple(
            proto: .tcp,
            source: Endpoint(address: gateway, port: srcPort),
            destination: Endpoint(address: fake, port: 443)
        )
    }

    private func connection(for tuple: FiveTuple) -> Connection {
        Connection(
            fiveTuple: tuple,
            app: AppIdentity(pid: 1778, displayName: "Safari"),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func mergesRealBytesAndDomainOntoZeroByteConnection() throws {
        let gateway = try address("198.19.0.1")
        let fake = try address("198.0.0.60")
        let ft = tuple(gateway: gateway, srcPort: 52750, fake: fake)
        let flow = TunneledFlowReconstructor.ReconstructedFlow(
            flowKey: ft.flowKey,
            pid: 1778,
            domain: "www.cloudflare.com",
            fakeDestination: ft.destination,
            bytesOut: 517,
            bytesIn: 1400
        )

        let merged = TunneledFlowStitch.merge(connection: connection(for: ft), flow: flow)

        #expect(merged.bytesOut == 517)
        #expect(merged.bytesIn == 1400)
        #expect(merged.remoteHostname == "www.cloudflare.com")
    }

    @Test func matchesByFlowKeyOnly() throws {
        let gateway = try address("198.19.0.1")
        let fake = try address("198.0.0.60")
        let ft = tuple(gateway: gateway, srcPort: 52750, fake: fake)
        let conn = connection(for: ft)

        let matching = TunneledFlowReconstructor.ReconstructedFlow(
            flowKey: ft.flowKey,
            pid: 1778,
            domain: "www.cloudflare.com",
            fakeDestination: ft.destination,
            bytesOut: 1,
            bytesIn: 1
        )
        let other = tuple(gateway: gateway, srcPort: 9999, fake: fake)
        let nonMatching = TunneledFlowReconstructor.ReconstructedFlow(
            flowKey: other.flowKey,
            pid: 1778,
            domain: nil,
            fakeDestination: other.destination,
            bytesOut: 1,
            bytesIn: 1
        )

        #expect(TunneledFlowStitch.matches(connection: conn, flow: matching))
        #expect(!TunneledFlowStitch.matches(connection: conn, flow: nonMatching))
    }
}
