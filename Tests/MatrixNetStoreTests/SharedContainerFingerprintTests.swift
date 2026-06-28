import Foundation
import SwiftData
import Testing
@testable import MatrixNetStore

@Suite("Shared container with fingerprints")
@MainActor
struct SharedContainerFingerprintTests {
    @Test("the fingerprint model coexists with the other models in one container")
    func coexist() throws {
        let container = try SharedModelContainer.makeInMemory()
        let context = container.mainContext
        let epoch = Date(timeIntervalSince1970: 0)
        context.insert(AppFingerprintRecord(
            app: "Safari",
            ja4: "t13d_a_b",
            label: nil,
            transport: "tcp",
            firstSeen: epoch,
            lastSeen: epoch,
            count: 1
        ))
        context.insert(KnownDestinationRecord(app: "Safari", country: "US", firstSeen: epoch))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<AppFingerprintRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<KnownDestinationRecord>()).count == 1)
    }
}
