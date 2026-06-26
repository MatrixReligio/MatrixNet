import Testing
@testable import MatrixNetModel

@Suite("FiveTuple & FlowKey")
struct FiveTupleTests {
    private func endpoint(_ ip: String, _ port: UInt16) throws -> Endpoint {
        try Endpoint(address: #require(IPAddress(ip)), port: port)
    }

    @Test("flow key is identical for the two directions of the same flow")
    func flowKeyDirectionInsensitive() throws {
        let client = try endpoint("192.168.1.10", 51_000)
        let server = try endpoint("93.184.216.34", 443)

        let outbound = FiveTuple(proto: .tcp, source: client, destination: server)
        let inbound = FiveTuple(proto: .tcp, source: server, destination: client)

        #expect(outbound.flowKey == inbound.flowKey)
        #expect(outbound.flowKey.hashValue == inbound.flowKey.hashValue)
    }

    @Test("flow keys differ when protocol differs")
    func flowKeyProtocolSensitive() throws {
        let a = try endpoint("10.0.0.1", 1000)
        let b = try endpoint("10.0.0.2", 2000)
        let tcp = FiveTuple(proto: .tcp, source: a, destination: b)
        let udp = FiveTuple(proto: .udp, source: a, destination: b)
        #expect(tcp.flowKey != udp.flowKey)
    }

    @Test("flow keys differ when endpoints differ")
    func flowKeyEndpointSensitive() throws {
        let a = try endpoint("10.0.0.1", 1000)
        let b = try endpoint("10.0.0.2", 2000)
        let c = try endpoint("10.0.0.3", 2000)
        let one = FiveTuple(proto: .tcp, source: a, destination: b)
        let two = FiveTuple(proto: .tcp, source: a, destination: c)
        #expect(one.flowKey != two.flowKey)
    }

    @Test("same address with different ports yields different flow keys")
    func flowKeyPortSensitive() throws {
        let a = try endpoint("10.0.0.1", 1000)
        let b1 = try endpoint("10.0.0.2", 2000)
        let b2 = try endpoint("10.0.0.2", 2001)
        let one = FiveTuple(proto: .tcp, source: a, destination: b1)
        let two = FiveTuple(proto: .tcp, source: a, destination: b2)
        #expect(one.flowKey != two.flowKey)
    }

    @Test("transport protocol maps to and from IANA numbers", arguments: [
        (TransportProtocol.tcp, UInt8(6)),
        (.udp, 17),
        (.icmpv4, 1),
        (.icmpv6, 58),
        (.other(89), 89),
    ])
    func protocolNumberRoundTrip(_ proto: TransportProtocol, _ number: UInt8) {
        #expect(proto.ipProtocolNumber == number)
        #expect(TransportProtocol(ipProtocolNumber: number) == proto)
    }
}
