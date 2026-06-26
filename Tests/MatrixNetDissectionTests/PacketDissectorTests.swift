import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("PacketDissector – L2/L3/L4")
struct PacketDissectorTests {
    private let dissector = PacketDissector()

    // Ethernet(14) + IPv4(20) + TCP(20): a SYN to 93.184.216.34:443 from
    // 192.168.1.5:50000.
    private let tcpSynOverEthernet = """
    aabbccddeeff 112233445566 0800
    45 00 0028 1c46 4000 40 06 0000 c0a80105 5db8d822
    c350 01bb 00000000 00000000 5002 ffff 0000 0000
    """

    /// Ethernet(14) + IPv4(20) + UDP(8) + DNS query payload (12-byte header + qname).
    private let dnsQueryOverEthernet = """
    aabbccddeeff 112233445566 0800
    45 00 003c 0001 0000 40 11 0000 c0a80105 08080808
    c000 0035 0028 0000
    1234 0100 0001 0000 0000 0000 07 6578616d706c65 03 636f6d 00 0001 0001
    """

    /// IPv6(40) + TCP(20) over Ethernet: 2001:db8::1 -> 2606:4700::1111 port 51000->443.
    private let tcpOverIPv6Ethernet = """
    aabbccddeeff 112233445566 86dd
    60000000 0014 06 40
    20010db8000000000000000000000001
    26064700000000000000000000001111
    c738 01bb 00000000 00000000 5002 ffff 0000 0000
    """

    @Test("dissects Ethernet → IPv4 → TCP and extracts the five-tuple")
    func tcpOverIPv4() throws {
        let packet = dissector.dissect(hex(tcpSynOverEthernet), linkType: .ethernet)
        #expect(packet.protocolPath == ["Ethernet", "IPv4", "TCP"])

        let tuple = try #require(packet.fiveTuple)
        #expect(tuple.proto == .tcp)
        #expect(tuple.source.address == IPAddress("192.168.1.5"))
        #expect(tuple.source.port == 50000)
        #expect(tuple.destination.address == IPAddress("93.184.216.34"))
        #expect(tuple.destination.port == 443)
        #expect(packet.highestProtocol == "TCP")
    }

    @Test("exposes IPv4 header fields for the detail tree")
    func ipv4Fields() throws {
        let packet = dissector.dissect(hex(tcpSynOverEthernet), linkType: .ethernet)
        let ip = try #require(packet.layers.first { $0.shortName == "IPv4" })
        let ttl = try #require(ip.fields.first { $0.name == "Time to Live" })
        #expect(ttl.value == "64")
        let proto = try #require(ip.fields.first { $0.name == "Protocol" })
        #expect(proto.value.contains("TCP"))
    }

    @Test("decodes TCP flags")
    func tcpFlags() throws {
        let packet = dissector.dissect(hex(tcpSynOverEthernet), linkType: .ethernet)
        let tcp = try #require(packet.layers.first { $0.shortName == "TCP" })
        let flags = try #require(tcp.fields.first { $0.name == "Flags" })
        #expect(flags.value.contains("SYN"))
    }

    @Test("dissects Ethernet → IPv4 → UDP")
    func udpOverIPv4() throws {
        let packet = dissector.dissect(hex(dnsQueryOverEthernet), linkType: .ethernet)
        #expect(packet.protocolPath == ["Ethernet", "IPv4", "UDP", "DNS"])
        let tuple = try #require(packet.fiveTuple)
        #expect(tuple.proto == .udp)
        #expect(tuple.destination.port == 53)
        #expect(packet.highestProtocol == "DNS")
    }

    @Test("dissects Ethernet → IPv6 → TCP and extracts the five-tuple")
    func tcpOverIPv6() throws {
        let packet = dissector.dissect(hex(tcpOverIPv6Ethernet), linkType: .ethernet)
        #expect(packet.protocolPath == ["Ethernet", "IPv6", "TCP"])
        let tuple = try #require(packet.fiveTuple)
        #expect(tuple.source.address == IPAddress("2001:db8::1"))
        #expect(tuple.destination.address == IPAddress("2606:4700::1111"))
        #expect(tuple.destination.port == 443)
    }

    // MARK: - Boundary / malformed inputs (must never crash)

    @Test("an empty buffer yields no layers and no crash")
    func emptyBuffer() {
        let packet = dissector.dissect([], linkType: .ethernet)
        #expect(packet.layers.isEmpty)
        #expect(packet.fiveTuple == nil)
    }

    @Test("truncation at every length still produces a stable, crash-free result")
    func truncationFuzz() {
        let full = hex(tcpSynOverEthernet)
        for length in 0 ... full.count {
            let truncated = Array(full.prefix(length))
            let packet = dissector.dissect(truncated, linkType: .ethernet)
            // Never more layers than the full packet; never crashes.
            #expect(packet.protocolPath.count <= 3)
        }
    }

    @Test("a bogus IPv4 header length does not over-read")
    func bogusIPv4HeaderLength() {
        // IHL nibble = 15 (60 bytes) but only 20 present; must not crash.
        var bytes = hex(tcpSynOverEthernet)
        bytes[14] = 0x4F
        let packet = dissector.dissect(bytes, linkType: .ethernet)
        #expect(packet.protocolPath.first == "Ethernet")
    }

    @Test("an unknown ethertype stops cleanly after the link layer")
    func unknownEthertype() {
        var bytes = hex(tcpSynOverEthernet)
        bytes[12] = 0x88
        bytes[13] = 0xB5 // experimental ethertype
        let packet = dissector.dissect(bytes, linkType: .ethernet)
        #expect(packet.protocolPath == ["Ethernet"])
        #expect(packet.fiveTuple == nil)
    }

    @Test("raw IP link type starts at the IP header")
    func rawIPLink() throws {
        let full = hex(tcpSynOverEthernet)
        let ipOnward = Array(full.dropFirst(14))
        let packet = dissector.dissect(ipOnward, linkType: .rawIP)
        #expect(packet.protocolPath == ["IPv4", "TCP"])
        #expect(try #require(packet.fiveTuple).destination.port == 443)
    }
}
