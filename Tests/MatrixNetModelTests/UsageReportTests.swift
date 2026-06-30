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

    // MARK: - Tooltip bucket selection (chart hover)

    private var buckets: [TrendBucket] {
        [
            TrendBucket(start: Date(timeIntervalSince1970: 0), totals: UsageTotals(bytesIn: 1, bytesOut: 0)),
            TrendBucket(start: Date(timeIntervalSince1970: 86400), totals: UsageTotals(bytesIn: 2, bytesOut: 0)),
            TrendBucket(start: Date(timeIntervalSince1970: 172_800), totals: UsageTotals(bytesIn: 3, bytesOut: 0))
        ]
    }

    @Test("bucket(at:) returns nil for an empty trend")
    func bucketEmpty() {
        #expect(UsageReport.bucket(at: Date(timeIntervalSince1970: 0), in: []) == nil)
    }

    @Test("bucket(at:) snaps to the nearest bucket by start")
    func bucketNearest() {
        // 50_000 is nearer day-1 (Δ36_400) than day-0 (Δ50_000).
        #expect(UsageReport.bucket(at: Date(timeIntervalSince1970: 50000), in: buckets)?.start
            == Date(timeIntervalSince1970: 86400))
    }

    @Test("bucket(at:) matches an exact bucket start")
    func bucketExact() {
        #expect(UsageReport.bucket(at: Date(timeIntervalSince1970: 172_800), in: buckets)?.totals.bytesIn == 3)
    }

    @Test("bucket(at:) clamps a date before the first bucket to the first")
    func bucketBeforeStart() {
        #expect(UsageReport.bucket(at: Date(timeIntervalSince1970: -100), in: buckets)?.start
            == Date(timeIntervalSince1970: 0))
    }
}
