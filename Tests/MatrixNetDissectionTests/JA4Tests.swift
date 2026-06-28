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
        0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030,
        0xCCA9, 0xCCA8, 0xC013, 0xC014, 0x009C, 0x009D, 0x002F, 0x0035
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

@Suite("JA4_c extensions")
struct JA4CTests {
    let extensions: [UInt16] = [
        0x001B, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002D, 0x000D,
        0x0005, 0x0023, 0x0012, 0x002B, 0xFF01, 0x000B, 0x000A, 0x0015
    ]
    let sigAlgs: [UInt16] = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

    @Test("raw list removes SNI+ALPN+GREASE, sorts extensions, keeps sig-alg order")
    func raw() {
        let expected = "0005,000a,000b,000d,0012,0015,0017,001b,0023,002b,002d,0033,4469,ff01"
            + "_0403,0804,0401,0503,0805,0501,0806,0601"
        #expect(JA4.rawC(extensions: [0x0A0A] + extensions, signatureAlgorithms: sigAlgs) == expected)
    }

    @Test("hash matches the FoxIO reference vector")
    func hash() {
        #expect(JA4.partC(extensions: extensions, signatureAlgorithms: sigAlgs) == "e5627efa2ab1")
    }

    @Test("no signature algorithms means no trailing underscore")
    func noSigAlgs() {
        #expect(JA4.rawC(extensions: [0x002B, 0x000A], signatureAlgorithms: []) == "000a,002b")
    }

    @Test("no extensions after exclusions hashes to the zero sentinel")
    func empty() {
        #expect(JA4.partC(extensions: [0x0000, 0x0010, 0x1A1A], signatureAlgorithms: []) == "000000000000")
    }
}

@Suite("JA4_a and full string")
struct JA4AfullTests {
    private func reference() -> JA4ClientHello {
        JA4ClientHello(
            tlsVersion: 0x0304,
            ciphers: [
                0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030,
                0xCCA9, 0xCCA8, 0xC013, 0xC014, 0x009C, 0x009D, 0x002F, 0x0035
            ],
            extensions: [
                0x001B, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002D, 0x000D,
                0x0005, 0x0023, 0x0012, 0x002B, 0xFF01, 0x000B, 0x000A, 0x0015
            ],
            signatureAlgorithms: [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601],
            alpnFirst: Array("h2".utf8),
            hasSNI: true
        )
    }

    @Test("JA4_a matches the reference vector")
    func partA() {
        #expect(JA4.rawA(from: reference(), transport: .tcp) == "t13d1516h2")
    }

    @Test("full JA4 string matches the FoxIO reference vector")
    func full() {
        #expect(JA4.string(from: reference(), transport: .tcp) == "t13d1516h2_8daaf6152771_e5627efa2ab1")
    }

    @Test("no SNI yields i, no ALPN yields 00, GREASE excluded from counts, count caps at 99")
    func variants() {
        var hello = reference()
        hello.hasSNI = false
        hello.alpnFirst = nil
        hello.ciphers = [0x0A0A] + Array(repeating: 0x1301, count: 120)
        let value = JA4.rawA(from: hello, transport: .tcp)
        #expect(value.hasPrefix("t13i")) // version 13, no SNI
        #expect(value.contains("99")) // cipher count capped
        #expect(value.hasSuffix("00")) // no ALPN
    }

    @Test("ALPN http/1.1 maps to h1; quic transport prefixes q")
    func alpnAndQuic() {
        var hello = reference()
        hello.alpnFirst = Array("http/1.1".utf8)
        #expect(JA4.rawA(from: hello, transport: .quic).hasPrefix("q13d"))
        #expect(JA4.rawA(from: hello, transport: .quic).hasSuffix("h1"))
    }

    @Test("a non-ASCII first ALPN byte yields 99 (FoxIO reference behavior)")
    func alpnNonASCII() {
        var hello = reference()
        hello.alpnFirst = [0xAB, 0xCD]
        #expect(JA4.rawA(from: hello, transport: .tcp).hasSuffix("99"))
    }
}
