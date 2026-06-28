import Testing
@testable import MatrixNetDissection

@Suite("QUIC varint")
struct QUICVarintTests {
    // RFC 9000 Appendix A.1 sample encodings.
    @Test("decodes 1/2/4/8-byte variable-length integers")
    func samples() throws {
        #expect(QUICVarint.decode([0x25], at: 0)?.value == 37)
        #expect(QUICVarint.decode([0x25], at: 0)?.length == 1)
        // Two-byte 0x7bbd = 15293.
        #expect(QUICVarint.decode([0x7b, 0xbd], at: 0)?.value == 15293)
        #expect(QUICVarint.decode([0x7b, 0xbd], at: 0)?.length == 2)
        // Two-byte encoding of 37 (0x4025) decodes to the same value.
        #expect(QUICVarint.decode([0x40, 0x25], at: 0)?.value == 37)
        // Four-byte 0x9d7f3e7d = 494878333.
        #expect(QUICVarint.decode([0x9d, 0x7f, 0x3e, 0x7d], at: 0)?.value == 494_878_333)
        #expect(QUICVarint.decode([0x9d, 0x7f, 0x3e, 0x7d], at: 0)?.length == 4)
        // Eight-byte 0xc2197c5eff14e88c = 151288809941952652.
        let eight: [UInt8] = [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]
        #expect(QUICVarint.decode(eight, at: 0)?.value == 151_288_809_941_952_652)
        #expect(QUICVarint.decode(eight, at: 0)?.length == 8)
    }

    @Test("a truncated buffer returns nil")
    func truncated() {
        #expect(QUICVarint.decode([0x9d, 0x7f], at: 0) == nil) // claims 4 bytes, only 2
    }
}
