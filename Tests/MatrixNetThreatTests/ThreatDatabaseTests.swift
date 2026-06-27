import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetThreat

@Suite("ThreatDatabase")
struct ThreatDatabaseTests {
    private func value(_ text: String) -> UInt32 {
        (IPAddress(text)?.bytes ?? []).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private func sample() -> ThreatDatabase {
        ThreatDatabase(addresses: [
            value("203.0.113.7"),
            value("8.8.8.8"),
            value("198.51.100.23")
        ])
    }

    @Test("flags listed addresses and clears unlisted ones")
    func membership() throws {
        let database = sample()
        #expect(try database.contains(#require(IPAddress("8.8.8.8"))))
        #expect(try database.contains(#require(IPAddress("203.0.113.7"))))
        #expect(try !database.contains(#require(IPAddress("1.1.1.1"))))
    }

    @Test("IPv6 addresses are never flagged (list is IPv4)")
    func ipv6Miss() throws {
        #expect(try !sample().contains(#require(IPAddress("2606:4700:4700::1111"))))
    }

    @Test("serialises and parses back to an equivalent database")
    func roundTrip() throws {
        let data = sample().serialized()
        let parsed = try #require(ThreatDatabase(data: data))
        #expect(parsed.count == 3)
        #expect(try parsed.contains(#require(IPAddress("198.51.100.23"))))
        #expect(try !parsed.contains(#require(IPAddress("10.0.0.1"))))
    }

    @Test("rejects truncated data")
    func truncated() {
        // Claims 5 records but carries none.
        #expect(ThreatDatabase(data: Data([0, 0, 0, 5])) == nil)
    }

    @Test("an empty database reports empty and matches nothing")
    func empty() throws {
        let database = ThreatDatabase(addresses: [])
        #expect(database.isEmpty)
        #expect(try !database.contains(#require(IPAddress("8.8.8.8"))))
    }
}

@Suite("ThreatUpdatePolicy")
struct ThreatUpdatePolicyTests {
    @Test("never-checked always checks")
    func neverChecked() {
        #expect(ThreatUpdatePolicy.shouldCheck(now: Date(), lastChecked: nil))
    }

    @Test("checks again only after the interval elapses")
    func interval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-ThreatUpdatePolicy.checkInterval - 1)
        #expect(!ThreatUpdatePolicy.shouldCheck(now: now, lastChecked: recent))
        #expect(ThreatUpdatePolicy.shouldCheck(now: now, lastChecked: old))
    }

    @Test("validates non-empty well-formed databases only")
    func validation() {
        let good = ThreatDatabase(addresses: [1, 2, 3]).serialized()
        #expect(ThreatUpdatePolicy.isValidDatabase(good))
        #expect(!ThreatUpdatePolicy.isValidDatabase(ThreatDatabase(addresses: []).serialized()))
        #expect(!ThreatUpdatePolicy.isValidDatabase(Data([0, 1])))
    }
}
