import Testing
@testable import MatrixNetDissection

@Suite("QUIC Initial decryption")
struct QUICDecryptTests {
    /// RFC 9001 Appendix A.2: decrypting the sample protected Initial packet
    /// yields a payload whose first frame is a CRYPTO frame (0x06) carrying the
    /// ClientHello (`010000ed…`).
    @Test("decrypts the RFC 9001 Appendix A client Initial to its CRYPTO frame")
    func decryptsAppendixA() {
        let packet = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let plaintext = QUICInitialCrypto.decryptInitial(packet)
        #expect(plaintext != nil)
        // First frame: CRYPTO (0x06), offset 0x00, length varint 0x40f1, then the
        // ClientHello handshake header 0x010000ed.
        #expect(Array(plaintext?.prefix(8) ?? []) == hexBytes("060040f1010000ed"))
    }

    @Test("a non-Initial / garbage packet returns nil instead of crashing")
    func garbage() {
        #expect(QUICInitialCrypto.decryptInitial([0x40, 0x00, 0x00, 0x00]) == nil)
    }
}
