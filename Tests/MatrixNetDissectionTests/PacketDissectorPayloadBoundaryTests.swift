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
}
