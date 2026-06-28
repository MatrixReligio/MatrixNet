import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetGeoIP

@Suite("GeoIPDatabase")
struct GeoIPDatabaseTests {
    private func ipValue(_ text: String) -> UInt32 {
        let bytes = IPAddress(text)?.bytes ?? []
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private func sampleDatabase() -> GeoIPDatabase {
        GeoIPDatabase(ranges: [
            .init(start: ipValue("1.0.0.0"), end: ipValue("1.0.0.255"), country: "AU"),
            .init(start: ipValue("8.8.8.0"), end: ipValue("8.8.8.255"), country: "US"),
            .init(start: ipValue("9.9.9.0"), end: ipValue("9.9.9.255"), country: "CH")
        ])
    }

    @Test("looks up countries by range")
    func lookup() throws {
        let database = sampleDatabase()
        #expect(try database.country(for: #require(IPAddress("8.8.8.8"))) == "US")
        #expect(try database.country(for: #require(IPAddress("1.0.0.200"))) == "AU")
        #expect(try database.country(for: #require(IPAddress("9.9.9.9"))) == "CH")
    }

    @Test("returns nil for addresses outside all ranges")
    func miss() throws {
        #expect(try sampleDatabase().country(for: #require(IPAddress("203.0.113.1"))) == nil)
    }

    @Test("placeholder country codes resolve to nil, not a fake country")
    func placeholderCountryIsNil() throws {
        // DB-IP marks reserved/unallocated ranges "ZZ"/"XX"/"??"; these are not
        // real countries and must not surface as a destination.
        let database = GeoIPDatabase(ranges: [
            .init(start: ipValue("203.0.113.0"), end: ipValue("203.0.113.255"), country: "ZZ")
        ])
        #expect(try database.country(for: #require(IPAddress("203.0.113.5"))) == nil)
    }

    @Test("builds flag emoji from country codes")
    func flags() {
        #expect(GeoIPDatabase.flag(for: "US") == "🇺🇸")
        #expect(GeoIPDatabase.flag(for: "jp") == "🇯🇵")
        #expect(GeoIPDatabase.flag(for: "XYZ") == nil)
        #expect(GeoIPDatabase.flag(for: "1!") == nil)
    }

    @Test("placeholder country codes produce no flag (no ZZ tofu)")
    func placeholderCodesHaveNoFlag() {
        // DB-IP marks reserved/unknown ranges (e.g. loopback) "ZZ"; turning that
        // into 🇿🇿 renders as missing-glyph boxes, so it must yield no flag.
        #expect(GeoIPDatabase.flag(for: "ZZ") == nil)
        #expect(GeoIPDatabase.flag(for: "zz") == nil)
        #expect(GeoIPDatabase.flag(for: "XX") == nil)
        #expect(GeoIPDatabase.flag(for: "??") == nil)
    }

    @Test("loads from the compact binary format and looks up")
    func binaryRoundTrip() throws {
        var data = Data()
        func appendU32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(value >> UInt32(shift) & 0xFF))
            }
        }
        appendU32(1) // count
        appendU32(ipValue("8.8.8.0"))
        appendU32(ipValue("8.8.8.255"))
        data.append(contentsOf: Array("US".utf8))

        let database = try #require(GeoIPDatabase(data: data))
        #expect(try database.country(for: #require(IPAddress("8.8.8.8"))) == "US")
    }

    @Test("rejects truncated binary data")
    func rejectsTruncated() {
        #expect(GeoIPDatabase(data: Data([0, 0, 0, 1, 1, 2])) == nil)
    }

    // MARK: - IPv6

    private func v6Halves(_ text: String) -> (high: UInt64, low: UInt64) {
        guard case let .v6(high, low) = IPAddress(text) else {
            fatalError("not an IPv6 literal: \(text)")
        }
        return (high, low)
    }

    private func v6Range(_ start: String, _ end: String, _ country: String) -> GeoIPDatabase.V6Range {
        let lower = v6Halves(start)
        let upper = v6Halves(end)
        return GeoIPDatabase.V6Range(
            startHigh: lower.high,
            startLow: lower.low,
            endHigh: upper.high,
            endLow: upper.low,
            country: country
        )
    }

    @Test("looks up IPv6 addresses by range")
    func ipv6Lookup() throws {
        let database = GeoIPDatabase(ranges: [], v6Ranges: [
            v6Range("2001:4860:4860::", "2001:4860:4860::ffff", "US"),
            v6Range("2606:4700::", "2606:4700:ffff:ffff:ffff:ffff:ffff:ffff", "AU")
        ])
        #expect(try database.country(for: #require(IPAddress("2001:4860:4860::8888"))) == "US")
        #expect(try database.country(for: #require(IPAddress("2606:4700::1111"))) == "AU")
        #expect(try database.country(for: #require(IPAddress("2400::1"))) == nil)
    }

    @Test("IPv6 range endpoints are inclusive and crossing the high half excludes")
    func ipv6LexicographicBoundaries() throws {
        // Range stays within one `high` half but spans the `low` half fully.
        let database = GeoIPDatabase(ranges: [], v6Ranges: [
            v6Range("2000::", "2000:0:0:0:ffff:ffff:ffff:ffff", "JP")
        ])
        #expect(try database.country(for: #require(IPAddress("2000::"))) == "JP") // start inclusive
        #expect(try database.country(for: #require(IPAddress("2000::1"))) == "JP")
        #expect(try database
            .country(for: #require(IPAddress("2000:0:0:0:ffff:ffff:ffff:ffff"))) == "JP") // end inclusive
        // One past the end in the high half → outside.
        #expect(try database.country(for: #require(IPAddress("2000:0:0:1::"))) == nil)
    }

    @Test("IPv6 placeholder country codes resolve to nil")
    func ipv6PlaceholderIsNil() throws {
        let database = GeoIPDatabase(ranges: [], v6Ranges: [
            v6Range("::", "1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "ZZ")
        ])
        #expect(try database.country(for: #require(IPAddress("100::1"))) == nil)
    }

    @Test("isEmpty is true only when both the IPv4 and IPv6 tables are empty")
    func emptyOnlyWhenBothTablesEmpty() {
        #expect(GeoIPDatabase(ranges: [], v6Ranges: []).isEmpty)
        #expect(!GeoIPDatabase(
            ranges: [.init(start: ipValue("8.8.8.0"), end: ipValue("8.8.8.255"), country: "US")],
            v6Ranges: []
        ).isEmpty)
        #expect(!GeoIPDatabase(
            ranges: [],
            v6Ranges: [v6Range("2001::", "2001::ffff", "US")]
        ).isEmpty)
    }

    @Test("loads format v2 (IPv4 table + appended IPv6 section) and looks up both families")
    func ipv6BinaryFormatRoundTrip() throws {
        var data = Data()
        func appendU32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(value >> UInt32(shift) & 0xFF))
            }
        }
        func appendU64(_ value: UInt64) {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
        // IPv4 table: one US range.
        appendU32(1)
        appendU32(ipValue("8.8.8.0"))
        appendU32(ipValue("8.8.8.255"))
        data.append(contentsOf: Array("US".utf8))
        // IPv6 section: one CH range.
        let lower = v6Halves("2001:4860:4860::")
        let upper = v6Halves("2001:4860:4860::ffff")
        appendU32(1)
        appendU64(lower.high)
        appendU64(lower.low)
        appendU64(upper.high)
        appendU64(upper.low)
        data.append(contentsOf: Array("CH".utf8))

        let database = try #require(GeoIPDatabase(data: data))
        #expect(try database.country(for: #require(IPAddress("8.8.8.8"))) == "US")
        #expect(try database.country(for: #require(IPAddress("2001:4860:4860::8888"))) == "CH")
    }

    @Test("a legacy v1 file (no IPv6 tail) still loads; IPv4 resolves, IPv6 is nil")
    func legacyV4OnlyFileStillLoads() throws {
        var data = Data()
        func appendU32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(value >> UInt32(shift) & 0xFF))
            }
        }
        appendU32(1)
        appendU32(ipValue("8.8.8.0"))
        appendU32(ipValue("8.8.8.255"))
        data.append(contentsOf: Array("US".utf8))

        let database = try #require(GeoIPDatabase(data: data))
        #expect(!database.isEmpty)
        #expect(try database.country(for: #require(IPAddress("8.8.8.8"))) == "US")
        #expect(try database.country(for: #require(IPAddress("2001:4860:4860::8888"))) == nil)
    }

    @Test("rejects a truncated IPv6 section (declared count without records)")
    func rejectsTruncatedV6Section() {
        var data = Data()
        func appendU32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(value >> UInt32(shift) & 0xFF))
            }
        }
        appendU32(0) // empty IPv4 table
        appendU32(1) // claims one IPv6 record, but no record bytes follow
        #expect(GeoIPDatabase(data: data) == nil)
    }
}
