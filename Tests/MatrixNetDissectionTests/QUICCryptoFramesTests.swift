import Testing
@testable import MatrixNetDissection

@Suite("QUIC CRYPTO frames")
struct QUICCryptoFramesTests {
    /// The decrypted RFC 9001 Appendix A payload's CRYPTO frame reassembles to a
    /// ClientHello handshake message (0x010000ed…).
    @Test("reassembles the ClientHello from the decrypted Appendix A payload")
    func reassembleAppendixA() throws {
        let packet = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let plaintext = try #require(QUICInitialCrypto.decryptInitial(packet))
        let hello = QUICCryptoFrames.reassembleClientHello(plaintext)
        #expect(Array(hello?.prefix(4) ?? []) == hexBytes("010000ed"))
    }

    /// Out-of-order CRYPTO fragments are reordered by offset; PADDING is skipped.
    @Test("reorders fragments by offset and skips padding")
    func reorders() {
        // CRYPTO off=2 len=2 "cccc", PADDING, CRYPTO off=0 len=2 "aabb"
        let frames = hexBytes("06" + "02" + "02" + "cccc" + "00" + "06" + "00" + "02" + "aabb")
        #expect(QUICCryptoFrames.reassembleClientHello(frames) == hexBytes("aabbcccc"))
    }
}
