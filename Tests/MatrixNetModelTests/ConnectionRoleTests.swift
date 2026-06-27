import Testing
@testable import MatrixNetModel

@Suite("ConnectionRole")
struct ConnectionRoleTests {
    private func tuple(_ proto: TransportProtocol, _ localPort: UInt16, _ remotePort: UInt16) throws -> FiveTuple {
        let local = try Endpoint(address: #require(IPAddress("192.168.1.10")), port: localPort)
        let remote = try Endpoint(address: #require(IPAddress("93.184.216.34")), port: remotePort)
        return FiveTuple(proto: proto, source: local, destination: remote)
    }

    @Test("ephemeral local port to a service port is a client (outbound)")
    func clientWhenLocalEphemeral() throws {
        #expect(try tuple(.tcp, 51000, 443).role == .client)
    }

    @Test("service local port from an ephemeral remote port is a server (inbound)")
    func serverWhenRemoteEphemeral() throws {
        #expect(try tuple(.tcp, 443, 51000).role == .server)
    }

    @Test("between two registered ports the lower port is the server side")
    func lowerRegisteredPortIsServer() throws {
        #expect(try tuple(.tcp, 8080, 5228).role == .client)
        #expect(try tuple(.tcp, 5228, 8080).role == .server)
    }

    @Test("both ephemeral ports are ambiguous")
    func bothEphemeralUnknown() throws {
        #expect(try tuple(.tcp, 51000, 52000).role == .unknown)
    }

    @Test("portless protocols (ICMP) have no role")
    func portlessUnknown() throws {
        #expect(try tuple(.icmpv4, 0, 0).role == .unknown)
    }

    @Test("zero ports are ambiguous")
    func zeroPortUnknown() throws {
        #expect(try tuple(.tcp, 0, 443).role == .unknown)
    }

    @Test("UDP uses the same heuristic")
    func udpClient() throws {
        #expect(try tuple(.udp, 50000, 53).role == .client)
    }
}
