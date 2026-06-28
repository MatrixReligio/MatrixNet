import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageExport")
struct UsageExportTests {
    private let rows = [
        UsageRow(
            periodStart: Date(timeIntervalSince1970: 0),
            app: "Safari",
            host: "ex,ample.com",
            country: "US",
            bytesIn: 100,
            bytesOut: 20
        ),
    ]

    @Test("csv has a header and an escaped row")
    func csv() {
        let csv = UsageExport.csv(rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "app,country,host,bytes_in,bytes_out,period_start")
        // The host contains a comma, so it must be quoted.
        #expect(lines.dropFirst().first == "Safari,US,\"ex,ample.com\",100,20,1970-01-01T00:00:00Z")
    }

    @Test("a value with a quote is escaped by doubling")
    func csvQuoteEscaping() {
        let row = [UsageRow(
            periodStart: Date(timeIntervalSince1970: 0),
            app: "He said \"hi\"",
            host: "a.com",
            country: "US",
            bytesIn: 1,
            bytesOut: 2
        )]
        #expect(UsageExport.csv(row).contains("\"He said \"\"hi\"\"\""))
    }

    @Test("empty rows produce just the header")
    func emptyCSV() {
        #expect(UsageExport.csv([]) == "app,country,host,bytes_in,bytes_out,period_start")
    }

    @Test("json decodes back to the same fields")
    func json() throws {
        let data = try #require(UsageExport.json(rows).data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(decoded?.count == 1)
        #expect(decoded?.first?["app"] as? String == "Safari")
        #expect(decoded?.first?["host"] as? String == "ex,ample.com")
        #expect(decoded?.first?["bytesIn"] as? Int == 100)
        #expect(decoded?.first?["bytesOut"] as? Int == 20)
        #expect(decoded?.first?["periodStart"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test("empty rows produce an empty json array")
    func emptyJSON() {
        #expect(UsageExport.json([]) == "[]")
    }
}
