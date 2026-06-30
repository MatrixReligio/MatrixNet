import Testing
@testable import MatrixNetDissection

@Suite("QUICDissector")
struct QUICDissectorTests {
    /// End-to-end: the RFC 9001 Appendix A client Initial → SNI example.com and a
    /// QUIC JA4 fingerprint (transport prefix `q`).
    @Test("dissects a QUIC Initial to SNI + QUIC JA4")
    func dissectsAppendixA() {
        let packet = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let result = QUICDissector.dissect(packet, at: 0, detailed: true)
        #expect(result?.serverName == "example.com")
        #expect(result?.clientFingerprint?.hasPrefix("q13d") == true)
        #expect(result?.node.shortName == "QUIC")
    }

    @Test("a non-QUIC payload returns nil")
    func nonQUIC() {
        #expect(QUICDissector.dissect([0x40, 0x00, 0x00, 0x00], at: 0, detailed: true) == nil)
    }

    /// With trailing (coalesced/padding) bytes after the Initial, the node's
    /// byteRange must stop at the Initial's end, not run to the buffer end.
    @Test("byteRange does not over-claim trailing coalesced bytes")
    func byteRangeBounded() throws {
        let initial = hexBytes(QUICTestVectors.appendixAProtectedClientInitial)
        let withTrailing = initial + [UInt8](repeating: 0xFF, count: 200)
        let result = try #require(QUICDissector.dissect(withTrailing, at: 0, detailed: true))
        #expect(result.node.byteRange.upperBound == initial.count)
    }
}
