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

    // MARK: - shouldDownload

    @Test("with no database, download regardless of the throttle")
    func downloadWhenEmpty() {
        let recent = now.addingTimeInterval(-60)
        // Throttle would normally block, but an empty install must self-heal.
        #expect(GeoIPUpdatePolicy.shouldDownload(hasDatabase: false, force: false, now: now, lastChecked: recent))
    }

    @Test("with a database, respect the throttle")
    func downloadRespectsThrottleWhenPresent() {
        let recent = now.addingTimeInterval(-60)
        #expect(!GeoIPUpdatePolicy.shouldDownload(hasDatabase: true, force: false, now: now, lastChecked: recent))
        let old = now.addingTimeInterval(-(8 * 24 * 60 * 60))
        #expect(GeoIPUpdatePolicy.shouldDownload(hasDatabase: true, force: false, now: now, lastChecked: old))
    }

    @Test("force always downloads")
    func downloadWhenForced() {
        let recent = now.addingTimeInterval(-60)
        #expect(GeoIPUpdatePolicy.shouldDownload(hasDatabase: true, force: true, now: now, lastChecked: recent))
    }

    // MARK: - shouldRecordCheck (throttle only when we won't strand an empty install)

    @Test("record the check on success")
    func recordOnSuccess() {
        #expect(GeoIPUpdatePolicy.shouldRecordCheck(succeeded: true, hasDatabase: false))
        #expect(GeoIPUpdatePolicy.shouldRecordCheck(succeeded: true, hasDatabase: true))
    }

    @Test("on failure, record only when a database already exists")
    func recordOnFailure() {
        // Have a working DB → throttle the next check despite the failure.
        #expect(GeoIPUpdatePolicy.shouldRecordCheck(succeeded: false, hasDatabase: true))
        // No DB → keep retrying every launch until one is obtained.
        #expect(!GeoIPUpdatePolicy.shouldRecordCheck(succeeded: false, hasDatabase: false))
    }
}
