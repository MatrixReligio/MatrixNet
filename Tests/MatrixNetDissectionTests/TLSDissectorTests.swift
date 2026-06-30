import Testing
@testable import MatrixNetDissection

@Suite("TLSDissector")
struct TLSDissectorTests {
    /// TLS record (0x16 handshake, TLS1.0 record version 0301, len 0x0043=67)
    /// ClientHello (0x01, len 0x00003F=63): version 0303, 32-byte random,
    /// session_id len 0, 1 cipher suite (1301), 1 compression (00),
    /// extensions len 0x0014=20 -> server_name "example.com".
    private let clientHello = hex("""
    16 0301 0043
    01 00003F
    0303 0000000000000000000000000000000000000000000000000000000000000000
    00 0002 1301 01 00
    0014 0000 0010 000E 00 000B 6578616d706c652e636f6d
    """)

    @Test("extracts the SNI host from a ClientHello")
    func extractsSNI() throws {
        let result = try TLSDissector.dissect(clientHello, at: 0, detailed: true)
        #expect(result.node.shortName == "TLS")
        #expect(result.serverName == "example.com")
        let handshake = try #require(result.node.fields.first { $0.name == "Handshake Type" })
        #expect(handshake.value.contains("Client Hello"))
    }

    @Test("recognises TLS by content for sniffing")
    func sniffing() {
        #expect(TLSDissector.looksLikeTLS(clientHello, at: 0))
        #expect(!TLSDissector.looksLikeTLS(hex("4745540a"), at: 0)) // "GET\n" is not TLS
    }

    @Test("handles application data records without a handshake")
    func applicationData() throws {
        // 0x17 application data, version 0303, length 5, 5 encrypted bytes.
        let appData = hex("17 0303 0005 0102030405")
        let result = try TLSDissector.dissect(appData, at: 0, detailed: true)
        #expect(result.node.shortName == "TLS")
        #expect(result.serverName == nil)
    }

    @Test("truncated TLS records do not crash", arguments: 0 ... 40)
    func truncationFuzz(_ length: Int) {
        _ = try? TLSDissector.dissect(Array(clientHello.prefix(length)), at: 0, detailed: true)
        #expect(Bool(true))
    }

    @Test("a ClientHello with a lying extensions length does not over-read")
    func bogusExtensionsLength() {
        var bytes = clientHello
        // Extensions-length field sits at offset 50; corrupt it to a huge value.
        bytes[50] = 0xFF
        bytes[51] = 0xFF
        _ = try? TLSDissector.dissect(bytes, at: 0, detailed: true)
        #expect(Bool(true))
    }
}
