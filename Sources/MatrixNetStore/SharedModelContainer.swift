import Foundation
import SwiftData

/// Builds the single SwiftData container shared by every store.
///
/// Two invariants matter here:
///  1. **One container for all models.** Opening separate
///     `ModelContainer(for: SingleModel.self)` instances makes SwiftData migrate
///     the shared store to whichever schema opened last, dropping the other
///     models' tables (this lost connection history and broke usage).
///  2. **An app-private store URL.** The store lives at an explicit
///     `Application Support/MatrixNet/matrixnet.store` — the same private
///     subfolder GeoIP/Threat already use. This avoids two macOS pitfalls: the
///     default top-level `default.store` (shared with other non-sandboxed apps,
///     which corrupts schemas and risks touching their data) and the App Group
///     container (CoreData there makes macOS prompt "wants to access data from
///     other apps" on launch). The widget reads metrics.json, not SwiftData, so
///     the store does not need to be in the group container.
public enum SharedModelContainer {
    private static var schema: Schema {
        Schema([ConnectionHistoryRecord.self, UsageBucketRecord.self, KnownDestinationRecord.self])
    }

    /// `Application Support/MatrixNet/matrixnet.store`, creating the folder.
    private static func storeURL() throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MatrixNet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("matrixnet.store")
    }

    /// The persistent container holding all stored models, at the app-private
    /// URL. If an earlier build left an incompatible store there, SwiftData
    /// throws; we then reset that store once and recreate every table.
    public static func make() throws -> ModelContainer {
        try make(configuration: ModelConfiguration(schema: schema, url: storeURL()))
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
