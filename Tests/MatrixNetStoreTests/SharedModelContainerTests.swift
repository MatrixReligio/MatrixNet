import Foundation
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
}
