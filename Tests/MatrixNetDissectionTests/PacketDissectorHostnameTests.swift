import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("PacketDissector – hostname observations")
struct PacketDissectorHostnameTests {
    private let dissector = PacketDissector()

    /// Ethernet + IPv4(8.8.8.8→192.168.1.5) + UDP(53→49152) + DNS response
    /// answering example.com = 93.184.216.34.
    private let dnsResponse = """
    aabbccddeeff 112233445566 0800
    45 00 0049 0001 0000 40 11 0000 08080808 c0a80105
    0035 c000 0035 0000
    1234 8180 0001 0001 0000 0000
    07 6578616d706c65 03 636f6d 00 0001 0001
    C00C 0001 0001 0000012C 0004 5db8d822
    """

    /// Ethernet + IPv4(192.168.1.5→93.184.216.34) + TCP(50000→443) + TLS
    /// ClientHello with SNI example.com.
    private let tlsClientHello = """
    aabbccddeeff 112233445566 0800
    45 00 0070 1c46 4000 40 06 0000 c0a80105 5db8d822
    c350 01bb 00000000 00000000 5018 ffff 0000 0000
    16 0301 0043
    01 00003F
    0303 0000000000000000000000000000000000000000000000000000000000000000
    00 0002 1301 01 00
    0014 0000 0010 000E 00 000B 6578616d706c652e636f6d
    """

    private let tcpSyn = """
    aabbccddeeff 112233445566 0800
    45 00 0028 1c46 4000 40 06 0000 c0a80105 5db8d822
    c350 01bb 00000000 00000000 5002 ffff 0000 0000
    """

    @Test("DNS answers surface as (answer IP, queried name) observations")
    func dnsHostnames() throws {
        let packet = dissector.dissect(hex(dnsResponse), linkType: .ethernet)
        let ip = try #require(IPAddress("93.184.216.34"))
        #expect(packet.hostnames.contains(HostnameObservation(ip: ip, name: "example.com")))
    }

    @Test("a TLS ClientHello surfaces (destination IP, SNI)")
    func tlsHostnames() throws {
        let packet = dissector.dissect(hex(tlsClientHello), linkType: .ethernet)
        let ip = try #require(IPAddress("93.184.216.34"))
        #expect(packet.hostnames.contains(HostnameObservation(ip: ip, name: "example.com")))
    }

    @Test("a plain TCP SYN has no hostname observations")
    func noHostnames() {
        let packet = dissector.dissect(hex(tcpSyn), linkType: .ethernet)
        #expect(packet.hostnames.isEmpty)
    }

    /// Ethernet + IPv4 + UDP + DNS response for www.example.com that returns a
    /// CNAME (cdn.example.net) before the A record. The observation must bind the
    /// IP to the *queried* name, not the CNAME's canonical name.
    private let dnsCNAMEResponse = """
    aabbccddeeff 112233445566 0800
    45 00 0079 0001 0000 40 11 0000 08080808 c0a80105
    0035 c000 0065 0000
    1234 8180 0001 0002 0000 0000
    03 777777 07 6578616d706c65 03 636f6d 00 0001 0001
    C00C 0005 0001 0000012C 0011 03 63646e 07 6578616d706c65 03 6e6574 00
    03 63646e 07 6578616d706c65 03 6e6574 00 0001 0001 0000012C 0004 5db8d822
    """

    @Test("a CNAME chain binds the IP to the queried name, not the canonical name")
    func dnsCNAMEUsesQueriedName() throws {
        let packet = dissector.dissect(hex(dnsCNAMEResponse), linkType: .ethernet)
        let ip = try #require(IPAddress("93.184.216.34"))
        #expect(packet.hostnames.contains(HostnameObservation(ip: ip, name: "www.example.com")))
        #expect(!packet.hostnames.contains { $0.name == "cdn.example.net" })
    }
}
