import Foundation
import SQLite3
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
        ensureIndexes(at: configuration.url)
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

    /// The exact index DDL SwiftData emits for this schema's `#Index`
    /// declarations (names, columns, collation — captured from a fresh store).
    /// Keeping them identical means a backfilled store is indistinguishable
    /// from a freshly created one.
    private static let indexDDL = [
        """
        CREATE INDEX IF NOT EXISTS Z_ConnectionHistoryRecord_SwiftDataIndexOnBinaryappNameremoteHostproto \
        ON ZCONNECTIONHISTORYRECORD (ZAPPNAME COLLATE BINARY ASC, ZREMOTEHOST COLLATE BINARY ASC, \
        ZPROTO COLLATE BINARY ASC)
        """,
        """
        CREATE INDEX IF NOT EXISTS Z_ConnectionHistoryRecord_SwiftDataIndexOnBinarylastSeen \
        ON ZCONNECTIONHISTORYRECORD (ZLASTSEEN COLLATE BINARY ASC)
        """,
        """
        CREATE INDEX IF NOT EXISTS Z_UsageBucketRecord_SwiftDataIndexOnBinaryperiodStartapphostcountry \
        ON ZUSAGEBUCKETRECORD (ZPERIODSTART COLLATE BINARY ASC, ZAPP COLLATE BINARY ASC, \
        ZHOST COLLATE BINARY ASC, ZCOUNTRY COLLATE BINARY ASC)
        """,
        """
        CREATE INDEX IF NOT EXISTS Z_AppFingerprintRecord_SwiftDataIndexOnBinaryappja4 \
        ON ZAPPFINGERPRINTRECORD (ZAPP COLLATE BINARY ASC, ZJA4 COLLATE BINARY ASC)
        """,
        """
        CREATE INDEX IF NOT EXISTS Z_KnownDestinationRecord_SwiftDataIndexOnBinaryappcountry \
        ON ZKNOWNDESTINATIONRECORD (ZAPP COLLATE BINARY ASC, ZCOUNTRY COLLATE BINARY ASC)
        """
    ]

    /// Backfills the `#Index` indexes on stores created before they were
    /// declared. CoreData's entity version hashes do not cover index
    /// descriptions, so an index-only schema change never triggers a migration
    /// — without this, an existing store would stay unindexed forever while
    /// fresh stores get the indexes. `IF NOT EXISTS` makes it a no-op
    /// everywhere else, and any failure is ignored: an index is a performance
    /// aid, never worth failing the store open for. Verified against a copy of
    /// a real 1.8.14 production store (rows intact, SwiftData reopens cleanly,
    /// the upsert query plan switches to the index).
    static func ensureIndexes(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        for ddl in indexDDL {
            sqlite3_exec(db, ddl, nil, nil, nil)
        }
    }

    /// Moves the SQLite store and its `-wal`/`-shm` sidecars aside to a unique
    /// `.corrupt-<unix>-<uuid>` backup instead of deleting them, so a store that
    /// failed to open can still be recovered by hand. The UUID makes the backup
    /// name collision-proof: two failed opens in the same second would otherwise
    /// reuse the same name, the move would fail, and the second store would be
    /// lost. A move that genuinely fails leaves the original file untouched
    /// (recreation then throws and the caller runs without a store for the
    /// session) — never deleted, because losing the user's data is the worse
    /// outcome.
    private static func backUpStore(at url: URL) {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent(base + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let backup = directory.appendingPathComponent("\(base).corrupt-\(stamp)\(suffix)")
            try? manager.moveItem(at: source, to: backup)
        }
    }
}
