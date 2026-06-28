import Foundation
import Testing
@testable import MatrixNetStore

@Suite("FingerprintStore")
@MainActor
struct FingerprintStoreTests {
    @Test("repeated records de-duplicate and bump count + lastSeen")
    func upsert() throws {
        let store = try FingerprintStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        try store.record(app: "Safari", ja4: "t13d_a_b", label: "Chrome / Chromium", transport: "tcp", at: t0)
        try store.record(app: "Safari", ja4: "t13d_a_b", label: "Chrome / Chromium", transport: "tcp", at: t1)
        let loaded = try store.load()
        #expect(loaded["Safari"]?.count == 1)
        let fingerprint = try #require(loaded["Safari"]?.first)
        #expect(fingerprint.count == 2)
        #expect(fingerprint.firstSeen == t0)
        #expect(fingerprint.lastSeen == t1)
    }

    @Test("different fingerprints for one app are stored separately")
    func distinct() throws {
        let store = try FingerprintStore.inMemory()
        let now = Date(timeIntervalSince1970: 0)
        try store.record(app: "Safari", ja4: "t13d_a_b", label: nil, transport: "tcp", at: now)
        try store.record(app: "Safari", ja4: "t13d_c_d", label: nil, transport: "tcp", at: now)
        #expect(try store.load()["Safari"]?.count == 2)
    }
}
