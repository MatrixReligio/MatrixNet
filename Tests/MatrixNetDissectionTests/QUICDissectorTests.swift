import Testing
@testable import MatrixNetDissection

@Suite("QUICDissector")
struct QUICDissectorTests {
    /// End-to-end: the RFC 9001 Appendix A client Initial → SNI example.com and a
    /// QUIC JA4 fingerprint (transport prefix `q`).
    @Test("dissects a QUIC Initial to SNI + QUIC JA4")
    func dissectsAppendixA() {
        let packet = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let result = QUICDissector.dissect(packet, at: 0)
        #expect(result?.serverName == "example.com")
        #expect(result?.clientFingerprint?.hasPrefix("q13d") == true)
        #expect(result?.node.shortName == "QUIC")
    }

    @Test("a non-QUIC payload returns nil")
    func nonQUIC() {
        #expect(QUICDissector.dissect([0x40, 0x00, 0x00, 0x00], at: 0) == nil)
    }
}
