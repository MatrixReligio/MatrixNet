import Foundation
import Testing
@testable import MatrixNetModel
@testable import MatrixNetStore

@Suite("UsageStore")
@MainActor
struct UsageStoreTests {
    private let hour = Date(timeIntervalSince1970: 0)
    private func row(_ app: String, _ host: String, _ bytes: UInt64, at: Date) -> UsageRow {
        UsageRow(periodStart: at, app: app, host: host, country: "US", bytesIn: bytes, bytesOut: 0)
    }

    @Test("accumulate adds bytes for the same key")
    func additiveUpsert() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([row("A", "x", 10, at: hour)])
        try store.accumulate([row("A", "x", 5, at: hour)])
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 1)
        #expect(out[0].bytesIn == 15)
    }

    @Test("fetch range is half-open [start, end)")
    func fetchRange() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([
            row("A", "x", 10, at: hour),
            row("A", "y", 7, at: hour.addingTimeInterval(7200))
        ])
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 1)
    }

    @Test("compactHour folds the tail beyond n into ·other")
    func compact() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([
            row("A", "a", 100, at: hour), row("A", "b", 50, at: hour),
            row("A", "c", 9, at: hour), row("A", "d", 1, at: hour)
        ])
        try store.compactHour(hour, limit: 2)
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 3)
        #expect(out.contains { $0.host == UsageTruncation.otherHost && $0.bytesIn == 10 })
    }

    @Test("compactHour is idempotent")
    func compactIdempotent() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([
            row("A", "a", 100, at: hour), row("A", "b", 50, at: hour),
            row("A", "c", 9, at: hour), row("A", "d", 1, at: hour)
        ])
        try store.compactHour(hour, limit: 2)
        try store.compactHour(hour, limit: 2)
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 3)
    }

    @Test("compactHour folds even when exactly limit+1 destinations exist")
    func compactExactlyOverByOne() throws {
        let store = try UsageStore.inMemory()
        // 3 hosts at limit 2 → the input and truncated counts are both 3, so a
        // count-equality guard would wrongly skip folding the 3rd host.
        try store.accumulate([
            row("A", "a", 100, at: hour), row("A", "b", 50, at: hour), row("A", "c", 9, at: hour)
        ])
        try store.compactHour(hour, limit: 2)
        var out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 3)
        #expect(out.contains { $0.host == UsageTruncation.otherHost && $0.bytesIn == 9 })
        // And re-compacting leaves exactly one ·other row (idempotent).
        try store.compactHour(hour, limit: 2)
        out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count(where: { $0.host == UsageTruncation.otherHost }) == 1)
    }

    @Test("prune deletes rows older than the cutoff")
    func prune() throws {
        let store = try UsageStore.inMemory()
        let old = Date(timeIntervalSince1970: 0)
        let recent = Date(timeIntervalSince1970: 100_000)
        try store.accumulate([row("A", "x", 1, at: old), row("A", "y", 1, at: recent)])
        try store.prune(olderThan: Date(timeIntervalSince1970: 50000))
        let out = try store.fetch(range: (Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 200_000)))
        #expect(out.count == 1)
        #expect(out[0].host == "y")
    }
}
