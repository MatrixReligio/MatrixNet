import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("TCP segment extraction")
struct TCPSegmentTests {
    /// IPv4 + TCP, SYN+ACK, 4 payload bytes. Built by hand so the structured
    /// fields are predictable. IHL=5 (20-byte IP header), data offset=5 (20-byte
    /// TCP header), totalLength=44 (20+20+4).
    private func synAckPacket() -> [UInt8] {
        var packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x2C, // ver/IHL, DSCP, total length = 44
            0x00, 0x00, 0x40, 0x00, // id, flags/frag (DF)
            0x40, 0x06, 0x00, 0x00, // TTL, proto=6 (TCP), checksum
            0x0A, 0x00, 0x00, 0x01, // src 10.0.0.1
            0x0A, 0x00, 0x00, 0x02 // dst 10.0.0.2
        ]
        packet += [
            0x01, 0xBB, 0xC0, 0x00, // src port 443, dst port 49152
            0x00, 0x00, 0x10, 0x00, // sequence = 0x1000
            0x00, 0x00, 0x20, 0x00, // ack = 0x2000
            0x50, 0x12, 0xFF, 0xFF, // data offset 5, flags SYN+ACK (0x012), window
            0x00, 0x00, 0x00, 0x00 // checksum, urgent
        ]
        packet += [0xDE, 0xAD, 0xBE, 0xEF] // 4 payload bytes
        return packet
    }

    @Test("dissecting an IPv4 TCP packet yields a structured TCP segment")
    func extractsSegment() throws {
        let dissected = PacketDissector().dissect(synAckPacket(), linkType: .rawIP)
        let segment = try #require(dissected.tcpSegment)
        #expect(segment.flags == [.syn, .ack])
        #expect(segment.sequence == 0x1000)
        #expect(segment.acknowledgement == 0x2000)
        #expect(segment.payloadLength == 4)
    }

    @Test("a UDP packet has no TCP segment")
    func udpHasNoSegment() {
        // Minimal IPv4+UDP: totalLength 28, proto 17.
        let packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00, 0x00,
            0x40, 0x11, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x0A, 0x00, 0x00, 0x02,
            0x30, 0x39, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00
        ]
        #expect(PacketDissector().dissect(packet, linkType: .rawIP).tcpSegment == nil)
    }
}
