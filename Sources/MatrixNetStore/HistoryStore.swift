import Foundation
import SwiftData

/// Persists connection history with SwiftData, upserting by app + remote host +
/// protocol so cumulative bytes and sighting counts accumulate over time.
@MainActor
public final class HistoryStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// An in-memory store for tests and previews.
    public static func inMemory() throws -> HistoryStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ConnectionHistoryRecord.self, configurations: configuration)
        return HistoryStore(container: container)
    }

    /// A persistent store under Application Support.
    public static func persistent() throws -> HistoryStore {
        let container = try ModelContainer(for: ConnectionHistoryRecord.self)
        return HistoryStore(container: container)
    }

    /// Upserts a batch of observations. Observations sharing the same app +
    /// remote host + protocol within a single batch are collapsed first, so a
    /// 5-second sample counts as exactly one sighting no matter how many
    /// concurrent sockets an app holds to that host, and their bytes are summed
    /// rather than reduced to the largest single socket.
    public func record(_ summaries: [ConnectionSummary]) throws {
        let context = container.mainContext
        for group in Self.collapse(summaries) {
            let app = group.appName
            let host = group.remoteHost
            let proto = group.proto
            var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
                predicate: #Predicate { $0.appName == app && $0.remoteHost == host && $0.proto == proto }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                existing.bytesIn = max(existing.bytesIn, group.bytesIn)
                existing.bytesOut = max(existing.bytesOut, group.bytesOut)
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

    /// One collapsed observation per app+host+proto in a batch: bytes summed
    /// across the concurrent sockets, with the earliest and latest timestamps.
    private struct Group {
        let appName: String
        let remoteHost: String
        let proto: String
        var bytesIn: Int
        var bytesOut: Int
        var firstAt: Date
        var lastAt: Date
    }

    private static func collapse(_ summaries: [ConnectionSummary]) -> [Group] {
        var groups: [String: Group] = [:]
        var order: [String] = []
        for summary in summaries {
            let key = "\(summary.appName)\u{1F}\(summary.remoteHost)\u{1F}\(summary.proto)"
            if var group = groups[key] {
                group.bytesIn += summary.bytesIn
                group.bytesOut += summary.bytesOut
                group.firstAt = min(group.firstAt, summary.at)
                group.lastAt = max(group.lastAt, summary.at)
                groups[key] = group
            } else {
                groups[key] = Group(
                    appName: summary.appName,
                    remoteHost: summary.remoteHost,
                    proto: summary.proto,
                    bytesIn: summary.bytesIn,
                    bytesOut: summary.bytesOut,
                    firstAt: summary.at,
                    lastAt: summary.at
                )
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
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
