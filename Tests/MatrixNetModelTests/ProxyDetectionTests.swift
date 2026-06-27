import Testing
@testable import MatrixNetModel

@Suite("Proxy detection")
struct ProxyDetectionTests {
    private func endpoint(_ ip: String, _ port: UInt16) throws -> Endpoint {
        try Endpoint(address: #require(IPAddress(ip)), port: port)
    }

    @Test("a connection to a configured proxy endpoint routes through the proxy")
    func matchesConfiguredProxy() throws {
        let proxy = try endpoint("192.168.1.2", 8080)
        let detector = ProxyDetector(proxyEndpoints: [proxy])
        #expect(detector.routesThroughProxy(proxy))
        #expect(try !detector.routesThroughProxy(endpoint("192.168.1.2", 443)))
    }

    @Test("a loopback connection on a well-known proxy port routes through a local proxy")
    func matchesLoopbackProxyPort() throws {
        let detector = ProxyDetector()
        #expect(try detector.routesThroughProxy(endpoint("127.0.0.1", 7890)))
        #expect(try detector.routesThroughProxy(endpoint("127.0.0.1", 1080)))
    }

    @Test("an ordinary loopback port is not treated as a proxy")
    func ordinaryLoopbackNotProxy() throws {
        let detector = ProxyDetector()
        #expect(try !detector.routesThroughProxy(endpoint("127.0.0.1", 5432)))
    }

    @Test("a normal public connection does not route through a proxy")
    func publicNotProxy() throws {
        let detector = try ProxyDetector(proxyEndpoints: [endpoint("127.0.0.1", 7890)])
        #expect(try !detector.routesThroughProxy(endpoint("93.184.216.34", 443)))
    }

    @Test("known VPN/tunnel provider processes are detected", arguments: [
        "LoonTunnelProvider",
        "com.example.PacketTunnel",
        "WireGuardNetworkExtension",
        "Surge",
        "ClashX Pro"
    ])
    func detectsTunnelProcesses(_ name: String) {
        #expect(TunnelProcess.isTunnel(name))
    }

    @Test("ordinary apps are not flagged as tunnels", arguments: [
        "Safari",
        "Mail",
        "postgres",
        "Google Chrome"
    ])
    func ordinaryAppsNotTunnels(_ name: String) {
        #expect(!TunnelProcess.isTunnel(name))
    }
}
