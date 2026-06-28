import Testing
@testable import MatrixNetDissection

@Suite("HostnameNormalizer")
struct HostnameNormalizerTests {
    @Test("lowercases and strips the trailing root dot")
    func lowercasesAndStrips() {
        #expect(HostnameNormalizer.normalize("Example.COM.") == "example.com")
    }

    @Test("keeps an already-clean host unchanged")
    func cleanHost() {
        #expect(HostnameNormalizer.normalize("a.b") == "a.b")
    }

    @Test("empty or root-only input is rejected")
    func rejectsEmpty() {
        #expect(HostnameNormalizer.normalize("") == nil)
        #expect(HostnameNormalizer.normalize(".") == nil)
        #expect(HostnameNormalizer.normalize("   ") == nil)
    }
}
