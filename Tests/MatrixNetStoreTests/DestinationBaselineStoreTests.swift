import Foundation
import Testing
@testable import MatrixNetStore

@MainActor
@Suite("DestinationBaselineStore")
struct DestinationBaselineStoreTests {
    @Test("records dedupe by app+country and load aggregates per app")
    func recordsAndLoads() throws {
        let store = try DestinationBaselineStore.inMemory()
        try store.record(app: "A", country: "US", at: Date(timeIntervalSince1970: 10))
        try store.record(app: "A", country: "US", at: Date(timeIntervalSince1970: 20)) // duplicate ignored
        try store.record(app: "A", country: "DE", at: Date(timeIntervalSince1970: 30))
        try store.record(app: "B", country: "JP", at: Date(timeIntervalSince1970: 40))

        let baseline = try store.load()
        #expect(baseline["A"]?.countries == ["US", "DE"])
        #expect(baseline["A"]?.firstSeen == Date(timeIntervalSince1970: 10)) // earliest wins
        #expect(baseline["B"]?.countries == ["JP"])
        #expect(baseline.count == 2)
    }
}
