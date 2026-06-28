import Testing
@testable import MatrixNetDissection

@Suite("QUIC Initial header")
struct QUICInitialTests {
    /// RFC 9001 Appendix A.2 unprotected header, then padding to stand in for the
    /// protected packet number + payload.
    @Test("parses a QUIC v1 Initial long header")
    func parseInitial() {
        let packet = hexBytes("c000000001088394c8f03e5157080000449e") + [UInt8](repeating: 0, count: 64)
        let parsed = QUICInitial.parse(packet)
        #expect(parsed?.version == 1)
        #expect(parsed?.dcid == hexBytes("8394c8f03e515708"))
        #expect(parsed?.scid.isEmpty == true)
        #expect(parsed?.pnOffset == 18) // c0 + version(4) + dcidlen(1)+dcid(8) + scidlen(1) + token(1) + len(2)
    }

    @Test("rejects a short header (1-RTT) packet")
    func rejectsShortHeader() {
        // High bit clear → short header, not an Initial.
        #expect(QUICInitial.parse([0x40, 0x00, 0x00]) == nil)
    }
}
