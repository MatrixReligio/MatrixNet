import Testing
@testable import MatrixNetDissection

@Suite("JA4 GREASE")
struct JA4GreaseTests {
    @Test("GREASE values are detected, real values are not")
    func grease() {
        #expect(JA4.isGREASE(0x0A0A))
        #expect(JA4.isGREASE(0x1A1A))
        #expect(JA4.isGREASE(0xFAFA))
        #expect(!JA4.isGREASE(0x1301)) // TLS_AES_128_GCM_SHA256
        #expect(!JA4.isGREASE(0x00FF)) // SCSV — not GREASE
        #expect(!JA4.isGREASE(0x0A1A)) // bytes differ
    }
}
