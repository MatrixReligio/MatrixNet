import Foundation
import SwiftData

/// A persisted TLS client fingerprint for one app.
public struct StoredFingerprint: Sendable, Equatable {
    public let ja4: String
    public let label: String?
    public let transport: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let count: Int
}

/// Persists per-app TLS client fingerprints, de-duplicated by app + JA4.
@MainActor
public final class FingerprintStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// In-memory store for tests/previews (a single-model in-memory container is
    /// collision-free, so this does not need the shared container).
    public static func inMemory() throws -> FingerprintStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try FingerprintStore(container: ModelContainer(for: AppFingerprintRecord.self, configurations: config))
    }

    /// Records an observation, bumping count + lastSeen when (app, ja4) exists.
    public func record(app: String, ja4: String, label: String?, transport: String, at time: Date) throws {
        let context = container.mainContext
        var descriptor = FetchDescriptor<AppFingerprintRecord>(
            predicate: #Predicate { $0.app == app && $0.ja4 == ja4 }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.count += 1
            existing.lastSeen = max(existing.lastSeen, time)
            if let label { existing.label = label }
        } else {
            context.insert(AppFingerprintRecord(
                app: app,
                ja4: ja4,
                label: label,
                transport: transport,
                firstSeen: time,
                lastSeen: time,
                count: 1
            ))
        }
        try context.save()
    }

    /// All stored fingerprints grouped by app.
    public func load() throws -> [String: [StoredFingerprint]] {
        let records = try container.mainContext.fetch(FetchDescriptor<AppFingerprintRecord>())
        var result: [String: [StoredFingerprint]] = [:]
        for record in records {
            result[record.app, default: []].append(StoredFingerprint(
                ja4: record.ja4,
                label: record.label,
                transport: record.transport,
                firstSeen: record.firstSeen,
                lastSeen: record.lastSeen,
                count: record.count
            ))
        }
        return result
    }
}
