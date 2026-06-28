import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("PacketDissector – JA4")
struct PacketDissectorJA4Tests {
    private let dissector = PacketDissector()

    /// Ethernet + IPv4(192.168.1.5→93.184.216.34) + TCP(50000→443) + TLS
    /// ClientHello with SNI example.com (one cipher, one extension).
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

    @Test("a dissected TLS ClientHello packet exposes its JA4")
    func fingerprint() {
        let packet = dissector.dissect(hex(tlsClientHello), linkType: .ethernet)
        #expect(packet.tlsClientFingerprint?.hasPrefix("t1") == true)
    }

    @Test("a plain TCP SYN exposes no JA4")
    func noFingerprint() {
        let packet = dissector.dissect(hex(tcpSyn), linkType: .ethernet)
        #expect(packet.tlsClientFingerprint == nil)
    }
}
