import Foundation
import SwiftData
import Testing
@testable import MatrixNetModel
@testable import MatrixNetStore

@MainActor
@Suite("SharedModelContainer")
struct SharedModelContainerTests {
    @Test("all three stores coexist on one shared container without schema collision")
    func storesCoexist() throws {
        let container = try SharedModelContainer.makeInMemory()
        let history = HistoryStore(container: container)
        let usage = UsageStore(container: container)
        let baseline = DestinationBaselineStore(container: container)

        try history.record([
            ConnectionSummary(
                appName: "A",
                remoteHost: "x",
                proto: "TCP",
                bytesIn: 10,
                bytesOut: 5,
                at: Date(timeIntervalSince1970: 100)
            )
        ])
        try usage.accumulate([
            UsageRow(
                periodStart: Date(timeIntervalSince1970: 0),
                app: "A",
                host: "x",
                country: "US",
                bytesIn: 100,
                bytesOut: 20
            )
        ])
        try baseline.record(app: "A", country: "US", at: Date(timeIntervalSince1970: 0))

        // Each model persists independently — none migrated the others away.
        #expect(try history.recent().count == 1)
        #expect(try usage.fetch(range: (
            Date(timeIntervalSince1970: -1),
            Date(timeIntervalSince1970: 3600)
        )).count == 1)
        #expect(try baseline.load()["A"]?.countries == ["US"])
    }

    /// A store that fails to open (a transient lock, a permissions/disk problem, a
    /// migration failure — not necessarily real corruption) must be moved aside to
    /// a recoverable backup, NEVER silently deleted, before the store is recreated.
    @Test("a store that fails to open is backed up, not deleted, then recreated")
    func failedOpenBacksUpInsteadOfDeleting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrixnet-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("matrixnet.store")
        let garbage = Data("this is not a sqlite database".utf8)
        try garbage.write(to: url)

        let schema = Schema([
            ConnectionHistoryRecord.self,
            UsageBucketRecord.self,
            KnownDestinationRecord.self,
            AppFingerprintRecord.self
        ])
        // Recovery must succeed (the app still launches with a fresh store)…
        _ = try SharedModelContainer.make(configuration: ModelConfiguration(schema: schema, url: url))

        // …but the original bytes must survive in a backup, not be deleted.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = entries.filter { $0.contains("corrupt") }
        #expect(!backups.isEmpty)
        let mainBackup = try #require(backups.first { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(mainBackup)) == garbage)
    }
}
