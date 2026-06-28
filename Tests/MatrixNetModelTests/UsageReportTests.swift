import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageReport")
struct UsageReportTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func row(_ app: String, _ host: String, _ country: String, _ hour: Int, _ bytes: UInt64) -> UsageRow {
        UsageRow(
            periodStart: Date(timeIntervalSince1970: TimeInterval(hour * 3600)),
            app: app,
            host: host,
            country: country,
            bytesIn: bytes,
            bytesOut: 0
        )
    }

    private var rows: [UsageRow] {
        [
            row("A", "x", "US", 0, 100),
            row("A", "y", "DE", 0, 50),
            row("B", "z", "US", 1, 30),
            row("A", "x", "US", 1, 10)
        ]
    }

    @Test("totals sum every row")
    func totals() {
        #expect(UsageReport.totals(rows) == UsageTotals(bytesIn: 190, bytesOut: 0))
    }

    @Test("byApp groups and sorts descending")
    func byApp() {
        let report = UsageReport.byApp(rows)
        #expect(report.map(\.app) == ["A", "B"])
        #expect(report[0].totals.bytesIn == 160)
    }

    @Test("byCountry groups across apps")
    func byCountry() {
        let report = UsageReport.byCountry(rows)
        #expect(report.first { $0.country == "US" }?.totals.bytesIn == 140)
        #expect(report.first { $0.country == "DE" }?.totals.bytesIn == 50)
    }

    @Test("byDomain can filter to one app")
    func byDomain() {
        let report = UsageReport.byDomain(rows, app: "A")
        #expect(report.first { $0.host == "x" }?.totals.bytesIn == 110)
        #expect(report.contains { $0.host == "z" } == false)
    }

    @Test("hourly trend keeps each hour separate")
    func trendHour() {
        let report = UsageReport.trend(rows, by: .hour, calendar: cal)
        #expect(report.count == 2)
        #expect(report[0].totals.bytesIn == 150)
        #expect(report[1].totals.bytesIn == 40)
    }

    @Test("daily trend collapses hours into one day")
    func trendDay() {
        let report = UsageReport.trend(rows, by: .day, calendar: cal)
        #expect(report.count == 1)
        #expect(report[0].totals.bytesIn == 190)
    }
}
