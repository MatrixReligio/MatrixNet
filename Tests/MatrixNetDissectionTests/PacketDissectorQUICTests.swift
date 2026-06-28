import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("PacketDissector – QUIC")
struct PacketDissectorQUICTests {
    private let dissector = PacketDissector()

    private func u16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// Ethernet + IPv4(192.168.1.5→93.184.216.34) + UDP(50000→443) + the RFC 9001
    /// Appendix A QUIC Initial.
    private func quicFrame() -> [UInt8] {
        let quic = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let udp = u16(50000) + u16(443) + u16(8 + quic.count) + u16(0) + quic
        let ipLength = 20 + udp.count
        let ipv4 = [0x45, 0x00] + u16(ipLength) + [0x00, 0x01, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00]
            + [192, 168, 1, 5] + [93, 184, 216, 34]
        let ethernet: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x08, 0x00]
        return ethernet + ipv4 + udp
    }

    @Test("a UDP/443 QUIC Initial surfaces SNI + a QUIC JA4")
    func quicInitial() throws {
        let packet = dissector.dissect(quicFrame(), linkType: .ethernet)
        let ip = try #require(IPAddress("93.184.216.34"))
        #expect(packet.hostnames.contains(HostnameObservation(ip: ip, name: "example.com")))
        #expect(packet.tlsClientFingerprint?.hasPrefix("q") == true)
        #expect(packet.protocolPath.last == "QUIC")
    }
}
