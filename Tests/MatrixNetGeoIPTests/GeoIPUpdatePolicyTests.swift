import Foundation
import Testing
@testable import MatrixNetGeoIP

@Suite("GeoIPUpdatePolicy")
struct GeoIPUpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    @Test("never-checked always triggers a check")
    func neverChecked() {
        #expect(GeoIPUpdatePolicy.shouldCheck(now: now, lastChecked: nil))
    }

    @Test("recently checked does not trigger")
    func recentlyChecked() {
        let recent = now.addingTimeInterval(-60)
        #expect(!GeoIPUpdatePolicy.shouldCheck(now: now, lastChecked: recent))
    }

    @Test("a stale check triggers")
    func staleCheck() {
        let old = now.addingTimeInterval(-(8 * 24 * 60 * 60))
        #expect(GeoIPUpdatePolicy.shouldCheck(now: now, lastChecked: old))
    }

    @Test("exactly at the interval boundary triggers")
    func boundary() {
        let edge = now.addingTimeInterval(-GeoIPUpdatePolicy.checkInterval)
        #expect(GeoIPUpdatePolicy.shouldCheck(now: now, lastChecked: edge))
    }

    @Test("rejects garbage as an invalid database")
    func rejectsGarbage() {
        #expect(!GeoIPUpdatePolicy.isValidDatabase(Data("not a database".utf8)))
        #expect(!GeoIPUpdatePolicy.isValidDatabase(Data()))
    }

    @Test("rejects a structurally valid but empty database")
    func rejectsEmpty() {
        // A header declaring zero ranges parses but carries no data.
        let empty = Data([0, 0, 0, 0])
        #expect(!GeoIPUpdatePolicy.isValidDatabase(empty))
    }

    @Test("accepts a well-formed database with one range")
    func acceptsValid() {
        var bytes: [UInt8] = [0, 0, 0, 1] // count = 1
        bytes += [1, 2, 3, 0] // start IP
        bytes += [1, 2, 3, 255] // end IP
        bytes += Array("US".utf8) // country
        #expect(GeoIPUpdatePolicy.isValidDatabase(Data(bytes)))
    }
}
