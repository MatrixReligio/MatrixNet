import Testing
@testable import MatrixNetModel

@Suite("FiveTuple & FlowKey")
struct FiveTupleTests {
    private func endpoint(_ ip: String, _ port: UInt16) throws -> Endpoint {
        try Endpoint(address: #require(IPAddress(ip)), port: port)
    }

    @Test("flow key is identical for the two directions of the same flow")
    func flowKeyDirectionInsensitive() throws {
        let client = try endpoint("192.168.1.10", 51000)
        let server = try endpoint("93.184.216.34", 443)

        let outbound = FiveTuple(proto: .tcp, source: client, destination: server)
        let inbound = FiveTuple(proto: .tcp, source: server, destination: client)

        #expect(outbound.flowKey == inbound.flowKey)
        #expect(outbound.flowKey.hashValue == inbound.flowKey.hashValue)
    }

    @Test("flow keys differ when protocol differs")
    func flowKeyProtocolSensitive() throws {
        let local = try endpoint("10.0.0.1", 1000)
        let remote = try endpoint("10.0.0.2", 2000)
        let tcp = FiveTuple(proto: .tcp, source: local, destination: remote)
        let udp = FiveTuple(proto: .udp, source: local, destination: remote)
        #expect(tcp.flowKey != udp.flowKey)
    }

    @Test("flow keys differ when endpoints differ")
    func flowKeyEndpointSensitive() throws {
        let local = try endpoint("10.0.0.1", 1000)
        let remote = try endpoint("10.0.0.2", 2000)
        let otherRemote = try endpoint("10.0.0.3", 2000)
        let one = FiveTuple(proto: .tcp, source: local, destination: remote)
        let two = FiveTuple(proto: .tcp, source: local, destination: otherRemote)
        #expect(one.flowKey != two.flowKey)
    }

    @Test("same address with different ports yields different flow keys")
    func flowKeyPortSensitive() throws {
        let local = try endpoint("10.0.0.1", 1000)
        let remote = try endpoint("10.0.0.2", 2000)
        let otherPort = try endpoint("10.0.0.2", 2001)
        let one = FiveTuple(proto: .tcp, source: local, destination: remote)
        let two = FiveTuple(proto: .tcp, source: local, destination: otherPort)
        #expect(one.flowKey != two.flowKey)
    }

    @Test("flow key is direction-insensitive at the port boundaries", arguments: [
        (UInt16(0), UInt16(0)),
        (0, 65535),
        (65535, 65535)
    ])
    func flowKeyPortBoundaries(_ localPort: UInt16, _ remotePort: UInt16) throws {
        let local = try endpoint("10.0.0.1", localPort)
        let remote = try endpoint("10.0.0.2", remotePort)
        let outbound = FiveTuple(proto: .udp, source: local, destination: remote)
        let inbound = FiveTuple(proto: .udp, source: remote, destination: local)
        #expect(outbound.flowKey == inbound.flowKey)
    }

    @Test("self-connection (identical endpoints) has a stable flow key")
    func flowKeySelfConnection() throws {
        let same = try endpoint("127.0.0.1", 8080)
        let tuple = FiveTuple(proto: .tcp, source: same, destination: same)
        #expect(tuple.flowKey == tuple.flowKey)
        let reversed = FiveTuple(proto: .tcp, source: same, destination: same)
        #expect(tuple.flowKey == reversed.flowKey)
    }

    @Test("transport protocol maps to and from IANA numbers", arguments: [
        (TransportProtocol.tcp, UInt8(6)),
        (.udp, 17),
        (.icmpv4, 1),
        (.icmpv6, 58),
        (.other(89), 89)
    ])
    func protocolNumberRoundTrip(_ proto: TransportProtocol, _ number: UInt8) {
        #expect(proto.ipProtocolNumber == number)
        #expect(TransportProtocol(ipProtocolNumber: number) == proto)
    }
}
