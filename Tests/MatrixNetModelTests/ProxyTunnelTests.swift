import Testing
@testable import MatrixNetModel

@Suite("Proxy + tunnel classification")
struct ProxyTunnelTests {
    private let detector = ProxyDetector()

    private func endpoint(_ ip: String, _ port: UInt16) throws -> Endpoint {
        try Endpoint(address: #require(IPAddress(ip)), port: port)
    }

    @Test("an explicit local proxy counts regardless of tunnel state")
    func explicitProxy() throws {
        let proxy = try endpoint("127.0.0.1", 7890)
        #expect(detector.routesThroughProxyOrTunnel(proxy, systemTunneled: false))
    }

    @Test("when the default route is a tunnel, global destinations count as proxied")
    func tunneledGlobal() throws {
        let remote = try endpoint("1.1.1.1", 443)
        #expect(detector.routesThroughProxyOrTunnel(remote, systemTunneled: true))
        #expect(!detector.routesThroughProxyOrTunnel(remote, systemTunneled: false))
    }

    @Test("loopback and LAN destinations are not counted as tunneled")
    func tunneledExcludesLocal() throws {
        let loopback = try endpoint("127.0.0.1", 8080)
        let lan = try endpoint("192.168.1.20", 443)
        #expect(!detector.routesThroughProxyOrTunnel(loopback, systemTunneled: true))
        #expect(!detector.routesThroughProxyOrTunnel(lan, systemTunneled: true))
    }
}
