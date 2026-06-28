import Foundation
import MatrixNetModel
import SwiftData

/// Persists hourly usage buckets with SwiftData, upserting additively by
/// (hour, app, host, country) so a crash mid-hour loses at most one flush.
@MainActor
public final class UsageStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// An in-memory store for tests and previews.
    public static func inMemory() throws -> UsageStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: UsageBucketRecord.self, configurations: config)
        return UsageStore(container: container)
    }

    /// A persistent store under Application Support.
    public static func persistent() throws -> UsageStore {
        try UsageStore(container: ModelContainer(for: UsageBucketRecord.self))
    }

    /// Additively upserts each row's bytes into its (hour, app, host, country)
    /// bucket.
    public func accumulate(_ rows: [UsageRow]) throws {
        let context = container.mainContext
        for row in rows {
            let start = row.periodStart
            let app = row.app
            let host = row.host
            let country = row.country
            var descriptor = FetchDescriptor<UsageBucketRecord>(
                predicate: #Predicate {
                    $0.periodStart == start && $0.app == app && $0.host == host && $0.country == country
                }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                existing.bytesIn += clampInt(row.bytesIn)
                existing.bytesOut += clampInt(row.bytesOut)
            } else {
                context.insert(UsageBucketRecord(
                    periodStart: start,
                    app: app,
                    host: host,
                    country: country,
                    bytesIn: clampInt(row.bytesIn),
                    bytesOut: clampInt(row.bytesOut)
                ))
            }
        }
        try context.save()
    }

    /// Rewrites one hour's rows down to the top-N destinations per app, folding
    /// the tail into a synthetic "other" row. Idempotent.
    public func compactHour(_ hourStart: Date, limit: Int) throws {
        let context = container.mainContext
        let end = hourStart.addingTimeInterval(3600)
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart >= hourStart && $0.periodStart < end }
        )
        let records = try context.fetch(descriptor)
        let truncated = UsageTruncation.topN(records.map(Self.toRow), limit: limit)
        guard truncated.count != records.count else { return }
        for record in records {
            context.delete(record)
        }
        for row in truncated {
            context.insert(UsageBucketRecord(
                periodStart: row.periodStart,
                app: row.app,
                host: row.host,
                country: row.country,
                bytesIn: clampInt(row.bytesIn),
                bytesOut: clampInt(row.bytesOut)
            ))
        }
        try context.save()
    }

    /// All buckets whose start falls in `[range.start, range.end)`.
    public func fetch(range: (start: Date, end: Date)) throws -> [UsageRow] {
        let start = range.start
        let end = range.end
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart >= start && $0.periodStart < end }
        )
        return try container.mainContext.fetch(descriptor).map(Self.toRow)
    }

    /// Deletes buckets older than `cutoff`.
    public func prune(olderThan cutoff: Date) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart < cutoff }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    /// The distinct hour starts present before `before` (for catch-up compaction).
    public func distinctHours(before: Date) throws -> [Date] {
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart < before }
        )
        return try Array(Set(container.mainContext.fetch(descriptor).map(\.periodStart))).sorted()
    }

    private static func toRow(_ record: UsageBucketRecord) -> UsageRow {
        UsageRow(
            periodStart: record.periodStart,
            app: record.app,
            host: record.host,
            country: record.country,
            bytesIn: UInt64(max(0, record.bytesIn)),
            bytesOut: UInt64(max(0, record.bytesOut))
        )
    }
}

private func clampInt(_ value: UInt64) -> Int {
    Int(min(value, UInt64(Int.max)))
}
