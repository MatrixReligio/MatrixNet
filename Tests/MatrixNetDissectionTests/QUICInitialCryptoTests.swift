import Testing
@testable import MatrixNetDissection

@Suite("QUIC Initial crypto")
struct QUICInitialCryptoTests {
    private func bytes(_ hex: String) -> [UInt8] {
        var result = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index ..< next], radix: 16)!) // swiftlint:disable:this force_unwrapping
            index = next
        }
        return result
    }

    /// RFC 9001 Appendix A.1: from DCID 0x8394c8f03e515708 the client keys are fixed.
    @Test("derives the RFC 9001 Appendix A client key, iv, and hp from the DCID")
    func rfcVector() {
        let secrets = QUICInitialCrypto.initialSecrets(dcid: bytes("8394c8f03e515708"))
        #expect(secrets.key == bytes("1f369613dd76d5467730efcbe3b1a22d"))
        #expect(secrets.iv == bytes("fa044b2f42a3fd3b46fb255c"))
        #expect(secrets.hp == bytes("9f50449e04a0e810283a1e9933adedd2"))
    }

    /// RFC 9001 Appendix A.2: AES-ECB(hp, sample) → first 5 bytes are the mask.
    @Test("computes the RFC 9001 Appendix A header-protection mask")
    func headerProtectionMask() {
        let hp = bytes("9f50449e04a0e810283a1e9933adedd2")
        let sample = bytes("d1b1c98dd7689fb8ec11d242b123dc9b")
        let mask = QUICInitialCrypto.headerProtectionMask(hp: hp, sample: sample)
        #expect(Array(mask.prefix(5)) == bytes("437b9aec36"))
    }
}
