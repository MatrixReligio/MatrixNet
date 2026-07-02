import Foundation
import SQLite3
import SwiftData
import Testing
@testable import MatrixNetStore

/// CoreData's entity version hashes do not include index descriptions, so an
/// index-only schema change never triggers a migration: a store created before
/// the `#Index` declarations would stay unindexed forever. `ensureIndexes`
/// creates them directly (verified against a copy of a real 1.8.14 store).
@Suite("SharedModelContainer index backfill")
@MainActor
struct SharedModelContainerIndexTests {
    private func indexNames(at url: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'Z_%SwiftDataIndex%'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                names.append(String(cString: text))
            }
        }
        return names
    }

    @Test("ensureIndexes backfills an index that predates the schema's #Index")
    func backfillsDroppedIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrixnet-index-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("matrixnet.store")

        // A fresh store gets the indexes from SwiftData itself; drop one to
        // simulate a store created before the #Index declarations existed.
        let container = try SharedModelContainer.make(configuration: ModelConfiguration(url: url))
        let context = container.mainContext
        context.insert(ConnectionHistoryRecord(
            appName: "a", remoteHost: "b", proto: "TCP",
            firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
            bytesIn: 1, bytesOut: 1
        ))
        try context.save()
        let dropped = "Z_ConnectionHistoryRecord_SwiftDataIndexOnBinarylastSeen"
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        sqlite3_exec(db, "DROP INDEX \(dropped)", nil, nil, nil)
        sqlite3_close(db)
        #expect(!indexNames(at: url).contains(dropped))

        SharedModelContainer.ensureIndexes(at: url)

        let names = indexNames(at: url)
        #expect(names.contains(dropped))
        // Idempotent: running again must not fail or duplicate.
        SharedModelContainer.ensureIndexes(at: url)
        #expect(indexNames(at: url).count == names.count)
    }

    @Test("ensureIndexes is a no-op for a store that does not exist yet")
    func noopWithoutStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrixnet-missing-\(UUID().uuidString)")
            .appendingPathComponent("matrixnet.store")
        SharedModelContainer.ensureIndexes(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
