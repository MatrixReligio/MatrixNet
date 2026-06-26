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

    @Test("builds flag emoji from country codes")
    func flags() {
        #expect(GeoIPDatabase.flag(for: "US") == "🇺🇸")
        #expect(GeoIPDatabase.flag(for: "jp") == "🇯🇵")
        #expect(GeoIPDatabase.flag(for: "XYZ") == nil)
        #expect(GeoIPDatabase.flag(for: "1!") == nil)
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
}
