import Foundation
import MatrixNetModel
import SwiftData

/// Builds the single SwiftData container shared by every store.
///
/// Two invariants matter here:
///  1. **One container for all models.** Opening separate
///     `ModelContainer(for: SingleModel.self)` instances makes SwiftData migrate
///     the shared store to whichever schema opened last, dropping the other
///     models' tables (this lost connection history and broke usage).
///  2. **Store inside the Team-ID App Group container.** A non-App-Store app that
///     writes to the default user-level Application Support shares a `default.store`
///     with other apps — which makes macOS prompt "wants to access data from other
///     apps" and would let a reset touch another app's file. The Team-ID-prefixed
///     group container is private to this app and prompts silently.
public enum SharedModelContainer {
    private static var schema: Schema {
        Schema([ConnectionHistoryRecord.self, UsageBucketRecord.self, KnownDestinationRecord.self])
    }

    private static var configuration: ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(SharedMetricsStore.appGroupIdentifier)
        )
    }

    /// The persistent container holding all stored models, in the App Group
    /// container. If an earlier build left a single-model store there, SwiftData
    /// cannot widen it to the unified schema and throws; we then reset that store
    /// once (its contents were a transient baseline) and recreate every table.
    public static func make() throws -> ModelContainer {
        try make(configuration: configuration)
    }

    static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            reset(at: configuration.url)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// An in-memory container for tests and previews.
    public static func makeInMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// Deletes the SQLite store and its sidecar files at `url`.
    private static func reset(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(at: url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix))
        }
    }
}
