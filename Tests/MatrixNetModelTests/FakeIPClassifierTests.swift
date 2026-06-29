import Testing
@testable import MatrixNetModel

struct FakeIPClassifierTests {
    private func address(_ string: String) throws -> IPAddress {
        try #require(IPAddress(string))
    }

    @Test func reservedBenchmarkRangeIsSynthetic() throws {
        // 198.18.0.0/15 (RFC 2544) — Loon/Surge/Clash 默认网关与池常用
        let gateway = try address("198.19.0.1")
        let low = try address("198.18.0.0")
        let high = try address("198.19.255.255")
        #expect(FakeIPClassifier.isReservedSyntheticV4(gateway))
        #expect(FakeIPClassifier.isReservedSyntheticV4(low))
        #expect(FakeIPClassifier.isReservedSyntheticV4(high))
    }

    @Test func cgnatAndReservedAreSynthetic() throws {
        let cgnat = try address("100.64.0.1") // 100.64/10
        let reserved = try address("240.0.0.1") // 240/4
        #expect(FakeIPClassifier.isReservedSyntheticV4(cgnat))
        #expect(FakeIPClassifier.isReservedSyntheticV4(reserved))
    }

    @Test func realPublicIsNotSynthetic() throws {
        let google = try address("8.8.8.8")
        let realPublic = try address("101.226.100.232") // 真机 en0 上的真实公网 IP
        #expect(!FakeIPClassifier.isReservedSyntheticV4(google))
        #expect(!FakeIPClassifier.isReservedSyntheticV4(realPublic))
    }

    @Test func learnedProxyPoolIsSynthetic() throws {
        // 真机观察到的 fake 池 198.0.x.x 不在保留段,靠学习到的 /16 前缀命中
        let prefix16 = UInt32(0xC600_0000) >> 16 // 198.0.0.0/16
        let sut = FakeIPClassifier(learnedSyntheticPrefixes16: [prefix16])
        let fake = try address("198.0.0.60")
        let real = try address("8.8.8.8")
        #expect(sut.isSynthetic(fake))
        #expect(!sut.isSynthetic(real))
    }
}
