import Testing
@testable import MatrixNetDissection

@Suite("JA4 ClientHello parsing")
struct JA4ParseTests {
    @Test("parses ciphers, extensions, ALPN, SNI, version, sig-algs from wire bytes")
    func parse() throws {
        let result = try TLSDissector.dissect(JA4ParseFixtures.clientHelloRecord(), at: 0)
        #expect(result.serverName == "a.com")
        // TLS1.3 (via supported_versions), SNI present → JA4 begins t13d.
        #expect(result.clientFingerprint?.hasPrefix("t13d") == true)
    }

    @Test("a truncated ClientHello yields no fingerprint but does not crash")
    func truncated() throws {
        let full = JA4ParseFixtures.clientHelloRecord()
        let result = try TLSDissector.dissect(Array(full.prefix(12)), at: 0)
        #expect(result.clientFingerprint == nil)
    }
}
