import Testing
@testable import MatrixNetDissection

@Suite("JA4 identifier")
struct JA4IdentifierTests {
    @Test("an unknown fingerprint returns nil")
    func unknown() {
        #expect(JA4Identifier.identify("t13d000000_000000000000_000000000000") == nil)
    }

    @Test("a seeded fingerprint returns its label")
    func known() {
        // The FoxIO reference vector is a known Chrome fingerprint.
        let label = JA4Identifier.identify("t13d1516h2_8daaf6152771_e5627efa2ab1")
        #expect(label?.category == "Browser")
    }
}
