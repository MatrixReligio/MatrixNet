import Foundation
import SwiftData

/// Persists connection history with SwiftData, upserting by app + remote host +
/// protocol so cumulative bytes and sighting counts accumulate over time.
@MainActor
public final class HistoryStore {
    private let container: ModelContainer
    /// Per-connection last-seen cumulative byte counts, so each sample contributes
    /// only its growth. Keyed by the connection's stable id; pruned to the live
    /// set on every `record` so a closed connection's entry can't linger.
    private var lastSeen: [UUID: (bytesIn: Int, bytesOut: Int)] = [:]

    public init(container: ModelContainer) {
        self.container = container
    }

    /// An in-memory store for tests and previews.
    public static func inMemory() throws -> HistoryStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ConnectionHistoryRecord.self, configurations: configuration)
        return HistoryStore(container: container)
    }

    /// A persistent store backed by the one shared, app-private container.
    /// Routes through `SharedModelContainer` so it never creates a stray
    /// `default.store` at the top of Application Support (a location shared with
    /// other apps, which trips the macOS "access other apps' data" prompt).
    public static func persistent() throws -> HistoryStore {
        try HistoryStore(container: SharedModelContainer.make())
    }

    /// Upserts a batch of observations. Observations sharing the same app +
    /// remote host + protocol within a single batch are collapsed first, so a
    /// 5-second sample counts as exactly one sighting no matter how many
    /// concurrent sockets an app holds to that host, and their bytes are summed
    /// rather than reduced to the largest single socket.
    public func record(_ summaries: [ConnectionSummary]) throws {
        let context = container.mainContext
        for group in collapse(summaries) {
            let app = group.appName
            let host = group.remoteHost
            let proto = group.proto
            var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
                predicate: #Predicate { $0.appName == app && $0.remoteHost == host && $0.proto == proto }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                existing.bytesIn += group.bytesIn
                existing.bytesOut += group.bytesOut
                existing.sightings += 1
                existing.lastSeen = max(existing.lastSeen, group.lastAt)
                existing.firstSeen = min(existing.firstSeen, group.firstAt)
            } else {
                context.insert(ConnectionHistoryRecord(
                    appName: app,
                    remoteHost: host,
                    proto: proto,
                    firstSeen: group.firstAt,
                    lastSeen: group.lastAt,
                    bytesIn: group.bytesIn,
                    bytesOut: group.bytesOut
                ))
            }
        }
        try context.save()
    }

    /// One collapsed observation per app+host+proto in a batch: per-connection
    /// deltas summed across the concurrent sockets, with the earliest and latest
    /// timestamps.
    private struct Group {
        let appName: String
        let remoteHost: String
        let proto: String
        var bytesIn: Int
        var bytesOut: Int
        var firstAt: Date
        var lastAt: Date
    }

    /// Turns each summary's cumulative counters into the growth since that
    /// connection's previous sample, then groups by app+host+proto. Pruning
    /// `lastSeen` to the ids in this batch keeps the baseline from growing without
    /// bound (a closed connection's id is never reused within a session).
    private func collapse(_ summaries: [ConnectionSummary]) -> [Group] {
        var groups: [String: Group] = [:]
        var order: [String] = []
        var seenIDs = Set<UUID>()
        for summary in summaries {
            seenIDs.insert(summary.id)
            let previous = lastSeen[summary.id] ?? (bytesIn: 0, bytesOut: 0)
            let deltaIn = max(0, summary.bytesIn - previous.bytesIn)
            let deltaOut = max(0, summary.bytesOut - previous.bytesOut)
            lastSeen[summary.id] = (summary.bytesIn, summary.bytesOut)

            let key = "\(summary.appName)\u{1F}\(summary.remoteHost)\u{1F}\(summary.proto)"
            if var group = groups[key] {
                group.bytesIn += deltaIn
                group.bytesOut += deltaOut
                group.firstAt = min(group.firstAt, summary.at)
                group.lastAt = max(group.lastAt, summary.at)
                groups[key] = group
            } else {
                groups[key] = Group(
                    appName: summary.appName,
                    remoteHost: summary.remoteHost,
                    proto: summary.proto,
                    bytesIn: deltaIn,
                    bytesOut: deltaOut,
                    firstAt: summary.at,
                    lastAt: summary.at
                )
                order.append(key)
            }
        }
        lastSeen = lastSeen.filter { seenIDs.contains($0.key) }
        return order.compactMap { groups[$0] }
    }

    /// Deletes records whose last sighting is older than `cutoff`. Without this
    /// sweep the table grows monotonically (one row per app+host+proto ever
    /// seen), and with it every unindexed upsert scan.
    public func prune(olderThan cutoff: Date) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            predicate: #Predicate { $0.lastSeen < cutoff }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    /// Deletes SwiftData's persistent-history change log older than `cutoff`.
    ///
    /// This is unrelated to the connection-history *records* above: SwiftData
    /// tracks every save in ACHANGE/ATRANSACTION tables meant for cross-process
    /// change consumers — and MatrixNet has none (the widget reads metrics.json,
    /// not SwiftData). Left alone the log dwarfs the business data (a real
    /// 1.8.14 store measured ~180 MB of change log against ~14k business rows;
    /// purging shrank the file to 4 MB with every row intact).
    ///
    /// `nonisolated` with its own context so callers can run it off the main
    /// actor: the first purge of a long-lived store works through a large
    /// backlog (~3.5s measured on that same store).
    nonisolated public func purgeChangeHistory(olderThan cutoff: Date) throws {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.predicate = #Predicate { $0.timestamp < cutoff }
        let context = ModelContext(container)
        try context.deleteHistory(descriptor)
    }

    /// The most recently active history records, newest first.
    public func recent(limit: Int = 200) throws -> [ConnectionHistoryRecord] {
        var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try container.mainContext.fetch(descriptor)
    }
}
