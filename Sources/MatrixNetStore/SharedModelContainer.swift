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
        Schema([
            ConnectionHistoryRecord.self,
            UsageBucketRecord.self,
            KnownDestinationRecord.self,
            AppFingerprintRecord.self
        ])
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
    /// URL. If the store fails to open, the old files are moved aside to a
    /// recoverable backup (never deleted) and a fresh store is created.
    public static func make() throws -> ModelContainer {
        try make(configuration: ModelConfiguration(schema: schema, url: storeURL()))
    }

    static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A failed open is NOT necessarily real corruption — it can be a
            // transient lock, a permissions/disk problem, or a migration failure.
            // Deleting the store on any of these would silently destroy the user's
            // history, usage, destination baselines, and fingerprints. So move the
            // files aside to a timestamped backup the user (or a future migration)
            // can recover from, then recreate from a clean slate.
            backUpStore(at: configuration.url)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// An in-memory container for tests and previews.
    public static func makeInMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// Moves the SQLite store and its `-wal`/`-shm` sidecars aside to a
    /// timestamped `.corrupt-<unix>` backup instead of deleting them, so a store
    /// that failed to open can still be recovered by hand. Only if a file cannot
    /// be moved at all does it fall back to removing it, so the app can still
    /// launch rather than loop on the same broken store.
    private static func backUpStore(at url: URL) {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let stamp = String(Int(Date().timeIntervalSince1970))
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent(base + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let backup = directory.appendingPathComponent("\(base).corrupt-\(stamp)\(suffix)")
            do {
                try manager.moveItem(at: source, to: backup)
            } catch {
                try? manager.removeItem(at: source)
            }
        }
    }
}
