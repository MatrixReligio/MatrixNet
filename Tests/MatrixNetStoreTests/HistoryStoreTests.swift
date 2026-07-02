import Foundation
import SwiftData
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
        id: UUID = UUID(),
        at: Date = Date(timeIntervalSince1970: 1000)
    ) -> ConnectionSummary {
        ConnectionSummary(
            id: id,
            appName: app,
            remoteHost: host,
            proto: "TCP",
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            at: at
        )
    }

    @Test("records new observations")
    func recordsNew() throws {
        let store = try HistoryStore.inMemory()
        try store.record([summary("Safari", "apple.com"), summary("curl", "example.com")])
        #expect(try store.recent().count == 2)
    }

    @Test("repeat samples of one connection accumulate its growth, not double-count")
    func upserts() throws {
        let store = try HistoryStore.inMemory()
        // The SAME connection (shared id) sampled twice: cumulative 100 → 300.
        let conn = UUID()
        try store.record([summary(
            "Safari",
            "apple.com",
            bytesIn: 100,
            bytesOut: 50,
            id: conn,
            at: Date(timeIntervalSince1970: 1000)
        )])
        try store.record([summary(
            "Safari",
            "apple.com",
            bytesIn: 300,
            bytesOut: 80,
            id: conn,
            at: Date(timeIntervalSince1970: 2000)
        )])

        let records = try store.recent()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.sightings == 2)
        #expect(record.bytesIn == 300) // delta 100 + 200, not the cumulative counted twice
        #expect(record.bytesOut == 80)
        #expect(record.lastSeen == Date(timeIntervalSince1970: 2000))
        #expect(record.firstSeen == Date(timeIntervalSince1970: 1000))
    }

    @Test("separate sequential connections to the same host accumulate")
    func sequentialConnectionsAccumulate() throws {
        let store = try HistoryStore.inMemory()
        let connA = UUID()
        let connB = UUID()
        let host = "cdn.example"
        // Connection A downloads to 100, sampled twice, then closes.
        try store.record([summary("Safari", host, bytesIn: 60, bytesOut: 0, id: connA)])
        try store.record([summary("Safari", host, bytesIn: 100, bytesOut: 0, id: connA)])
        // A new, separate connection to the same host downloads 80.
        try store.record([summary("Safari", host, bytesIn: 80, bytesOut: 0, id: connB)])

        let record = try #require(try store.recent().first)
        // 100 (A) + 80 (B) — the old `max` kept only the larger single connection.
        #expect(record.bytesIn == 180)
    }

    @Test("collapses duplicate tuples within one batch: one sighting, summed bytes")
    func collapsesWithinBatch() throws {
        let store = try HistoryStore.inMemory()
        // Three concurrent sockets to the same app+host+proto, recorded together.
        try store.record([
            summary("Spark", "198.0.0.11", bytesIn: 100, bytesOut: 10, at: Date(timeIntervalSince1970: 1000)),
            summary("Spark", "198.0.0.11", bytesIn: 200, bytesOut: 20, at: Date(timeIntervalSince1970: 1002)),
            summary("Spark", "198.0.0.11", bytesIn: 300, bytesOut: 30, at: Date(timeIntervalSince1970: 1004))
        ])
        let records = try store.recent()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.sightings == 1) // one sample, not three
        #expect(record.bytesIn == 600) // summed across concurrent sockets
        #expect(record.bytesOut == 60)
        #expect(record.firstSeen == Date(timeIntervalSince1970: 1000)) // earliest in batch
        #expect(record.lastSeen == Date(timeIntervalSince1970: 1004)) // latest in batch
    }

    @Test("prune removes records last seen before the cutoff and keeps the rest")
    func pruneByLastSeen() throws {
        let store = try HistoryStore.inMemory()
        try store.record([
            summary("Old", "old.example", at: Date(timeIntervalSince1970: 1000)),
            summary("Fresh", "fresh.example", at: Date(timeIntervalSince1970: 5000))
        ])
        try store.prune(olderThan: Date(timeIntervalSince1970: 3000))
        let records = try store.recent()
        #expect(records.count == 1)
        #expect(records.first?.appName == "Fresh")
    }

    @Test("purgeChangeHistory drops SwiftData's persistent-history change log")
    func purgesChangeHistory() throws {
        // History tracking needs a file-backed store (in-memory stores skip it).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrixnet-history-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("matrixnet.store")
        let container = try SharedModelContainer.make(configuration: ModelConfiguration(url: url))
        let store = HistoryStore(container: container)

        try store.record([summary("Safari", "apple.com")])
        try store.record([summary("curl", "example.com")])

        let everything = HistoryDescriptor<DefaultHistoryTransaction>()
        #expect(try !container.mainContext.fetchHistory(everything).isEmpty)

        try store.purgeChangeHistory(olderThan: .distantFuture)

        #expect(try container.mainContext.fetchHistory(everything).isEmpty)
        // The business rows themselves must survive the purge untouched.
        #expect(try store.recent().count == 2)
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
