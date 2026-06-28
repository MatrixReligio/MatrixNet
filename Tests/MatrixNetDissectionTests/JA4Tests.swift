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

@Suite("JA4_b ciphers")
struct JA4BTests {
    let ciphers: [UInt16] = [
        0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030,
        0xcca9, 0xcca8, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035
    ]

    @Test("raw cipher list is GREASE-free and sorted ascending")
    func raw() {
        #expect(JA4.rawB(ciphers: [0x0A0A] + ciphers) ==
            "002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9")
    }

    @Test("hash matches the FoxIO reference vector")
    func hash() {
        #expect(JA4.partB(ciphers: ciphers) == "8daaf6152771")
    }

    @Test("no ciphers hashes to the zero sentinel")
    func empty() {
        #expect(JA4.partB(ciphers: [0x1A1A]) == "000000000000")
    }
}
