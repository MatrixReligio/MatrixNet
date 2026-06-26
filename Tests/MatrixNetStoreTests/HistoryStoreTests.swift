import Foundation
import Testing
@testable import MatrixNetStore

@Suite("HistoryStore")
@MainActor
struct HistoryStoreTests {
    private func summary(
        _ app: String,
        _ host: String,
        bytesIn: Int = 100,
        bytesOut: Int = 50,
        at: Date = Date(timeIntervalSince1970: 1000)
    ) -> ConnectionSummary {
        ConnectionSummary(appName: app, remoteHost: host, proto: "TCP", bytesIn: bytesIn, bytesOut: bytesOut, at: at)
    }

    @Test("records new observations")
    func recordsNew() throws {
        let store = try HistoryStore.inMemory()
        try store.record([summary("Safari", "apple.com"), summary("curl", "example.com")])
        #expect(try store.recent().count == 2)
    }

    @Test("upserts repeat observations by app + host + proto")
    func upserts() throws {
        let store = try HistoryStore.inMemory()
        try store.record([summary(
            "Safari",
            "apple.com",
            bytesIn: 100,
            bytesOut: 50,
            at: Date(timeIntervalSince1970: 1000)
        )])
        try store.record([summary(
            "Safari",
            "apple.com",
            bytesIn: 300,
            bytesOut: 80,
            at: Date(timeIntervalSince1970: 2000)
        )])

        let records = try store.recent()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.sightings == 2)
        #expect(record.bytesIn == 300) // monotonic max
        #expect(record.bytesOut == 80)
        #expect(record.lastSeen == Date(timeIntervalSince1970: 2000))
        #expect(record.firstSeen == Date(timeIntervalSince1970: 1000))
    }

    @Test("returns records newest-first and honours the limit")
    func recentOrderAndLimit() throws {
        let store = try HistoryStore.inMemory()
        try store.record([
            summary("A", "a.com", at: Date(timeIntervalSince1970: 1000)),
            summary("B", "b.com", at: Date(timeIntervalSince1970: 3000)),
            summary("C", "c.com", at: Date(timeIntervalSince1970: 2000))
        ])
        let top = try store.recent(limit: 2)
        #expect(top.count == 2)
        #expect(top.first?.appName == "B") // newest lastSeen first
    }
}
