import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("Application-layer payload boundary")
struct PacketDissectorPayloadBoundaryTests {
    /// A TCP/443 pure ACK (no application payload) whose captured buffer carries
    /// trailing bytes past the IP total length — link-layer padding, or a runt
    /// frame padded to the 60-byte Ethernet minimum. Those bytes are NOT
    /// application data: parsing must stop at the IP payload end, or the port-443
    /// trigger mints a bogus TLS layer out of padding.
    @Test("trailing padding past the IP payload end is not parsed as TLS")
    func paddingNotParsedAsApplication() {
        var packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x28, // ver/IHL, DSCP, total length = 40 (20 IP + 20 TCP, no payload)
            0x00, 0x00, 0x40, 0x00,
            0x40, 0x06, 0x00, 0x00, // TTL, proto = 6 (TCP)
            0x0A, 0x00, 0x00, 0x01, // src 10.0.0.1
            0x0A, 0x00, 0x00, 0x02 // dst 10.0.0.2
        ]
        packet += [
            0x01, 0xBB, 0xC0, 0x00, // src port 443, dst 49152
            0x00, 0x00, 0x10, 0x00,
            0x00, 0x00, 0x20, 0x00,
            0x50, 0x10, 0xFF, 0xFF, // data offset 5, flags ACK (0x010)
            0x00, 0x00, 0x00, 0x00
        ]
        // Trailing bytes shaped like a TLS handshake record header — the worst case.
        packet += [0x16, 0x03, 0x01, 0x00, 0x10, 0x01, 0x00, 0x00]

        let dissected = PacketDissector().dissect(packet, linkType: .rawIP)
        #expect(!dissected.layers.contains { $0.shortName == "TLS" })
        #expect(dissected.tlsClientFingerprint == nil)
    }

    /// An IPv4 packet whose total length covers only the IP header (no transport),
    /// but whose captured buffer has trailing padding shaped like a TCP header.
    /// The transport header must not be parsed from bytes outside the datagram —
    /// otherwise a bogus five-tuple is minted from padding.
    @Test("a TCP header past the IP payload end is not parsed")
    func transportHeaderPastPayloadEndRejected() {
        var packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x14, // ver/IHL, DSCP, total length = 20 (IP header only)
            0x00, 0x00, 0x40, 0x00,
            0x40, 0x06, 0x00, 0x00, // proto = 6 (TCP)
            0x0A, 0x00, 0x00, 0x01,
            0x0A, 0x00, 0x00, 0x02
        ]
        // 20 trailing bytes shaped like a TCP header (src port 443, data offset 5).
        packet += [
            0x01, 0xBB, 0xC0, 0x00,
            0x00, 0x00, 0x10, 0x00,
            0x00, 0x00, 0x20, 0x00,
            0x50, 0x10, 0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x00
        ]
        let dissected = PacketDissector().dissect(packet, linkType: .rawIP)
        #expect(dissected.fiveTuple == nil)
        #expect(!dissected.layers.contains { $0.shortName == "TCP" })
    }

    /// A UDP datagram whose length field is malformed (< the 8-byte header) must
    /// not be treated as license to parse the rest of the IP payload as the
    /// application layer.
    @Test("a malformed short UDP length yields no application layer")
    func malformedUDPLengthHasNoApplication() {
        var packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x24, // total length = 36 (20 IP + 8 UDP + 8 trailing)
            0x00, 0x00, 0x40, 0x00,
            0x40, 0x11, 0x00, 0x00, // proto = 17 (UDP)
            0x0A, 0x00, 0x00, 0x01,
            0x0A, 0x00, 0x00, 0x02
        ]
        packet += [
            0x00, 0x35, 0xC0, 0x00, // src port 53, dst 49152
            0x00, 0x04, 0x00, 0x00 // length = 4 (malformed: < 8), checksum
        ]
        // Trailing bytes that a DNS dissector might latch onto.
        packet += [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00]
        let dissected = PacketDissector().dissect(packet, linkType: .rawIP)
        #expect(!dissected.layers.contains { $0.shortName == "DNS" })
    }
}
