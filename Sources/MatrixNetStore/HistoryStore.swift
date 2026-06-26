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

    /// Upserts a batch of observations.
    public func record(_ summaries: [ConnectionSummary]) throws {
        let context = container.mainContext
        for summary in summaries {
            let app = summary.appName
            let host = summary.remoteHost
            let proto = summary.proto
            var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
                predicate: #Predicate { $0.appName == app && $0.remoteHost == host && $0.proto == proto }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                existing.bytesIn = max(existing.bytesIn, summary.bytesIn)
                existing.bytesOut = max(existing.bytesOut, summary.bytesOut)
                existing.sightings += 1
                existing.lastSeen = max(existing.lastSeen, summary.at)
                existing.firstSeen = min(existing.firstSeen, summary.at)
            } else {
                context.insert(ConnectionHistoryRecord(
                    appName: app,
                    remoteHost: host,
                    proto: proto,
                    firstSeen: summary.at,
                    lastSeen: summary.at,
                    bytesIn: summary.bytesIn,
                    bytesOut: summary.bytesOut
                ))
            }
        }
        try context.save()
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
