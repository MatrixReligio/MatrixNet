import Foundation
import Testing
@testable import MatrixNetModel

@Suite("ActivityTimelineBuilder")
struct ActivityTimelineBuilderTests {
    private let h0 = Date(timeIntervalSince1970: 0)
    private var hours: [Date] {
        (0 ..< 3).map { h0.addingTimeInterval(Double($0) * 3600) }
    }

    private func row(_ app: String, _ hourIndex: Int, _ bytes: UInt64) -> UsageRow {
        UsageRow(
            periodStart: h0.addingTimeInterval(Double(hourIndex) * 3600),
            app: app,
            host: "h",
            country: "US",
            bytesIn: bytes,
            bytesOut: 0
        )
    }

    @Test("aligns an app's hourly bytes to the bucket scale, filling gaps with 0")
    func aligns() {
        let timeline = ActivityTimelineBuilder.build(rows: [row("A", 0, 100), row("A", 2, 50)], hours: hours)
        #expect(timeline.rows.count == 1)
        #expect(timeline.rows[0].app == "A")
        #expect(timeline.rows[0].buckets == [100, 0, 50])
        #expect(timeline.rows[0].total == 150)
    }

    @Test("sums in+out and multiple hosts within the same bucket")
    func sums() {
        let rows = [
            UsageRow(periodStart: h0, app: "A", host: "h1", country: "US", bytesIn: 10, bytesOut: 5),
            UsageRow(periodStart: h0, app: "A", host: "h2", country: "US", bytesIn: 20, bytesOut: 0)
        ]
        let timeline = ActivityTimelineBuilder.build(rows: rows, hours: hours)
        #expect(timeline.rows[0].buckets[0] == 35)
    }

    @Test("orders apps by total descending")
    func order() {
        let timeline = ActivityTimelineBuilder.build(rows: [row("Small", 0, 1), row("Big", 0, 999)], hours: hours)
        #expect(timeline.rows.map(\.app) == ["Big", "Small"])
    }

    @Test("ignores rows outside the bucket scale and drops zero-total apps")
    func bounds() {
        let before = row("Old", -5, 100) // before hours.first
        let timeline = ActivityTimelineBuilder.build(rows: [before, row("A", 1, 10)], hours: hours)
        #expect(timeline.rows.map(\.app) == ["A"])
        #expect(timeline.rows[0].buckets == [0, 10, 0])
    }

    @Test("daily step maps any hour within a day into that day's bucket")
    func dailyStep() {
        let days = (0 ..< 2).map { h0.addingTimeInterval(Double($0) * 86400) }
        // 5 hours and 30 hours after h0 → day 0 and day 1 respectively.
        let rows = [
            UsageRow(
                periodStart: h0.addingTimeInterval(5 * 3600),
                app: "A",
                host: "h",
                country: "US",
                bytesIn: 7,
                bytesOut: 0
            ),
            UsageRow(
                periodStart: h0.addingTimeInterval(30 * 3600),
                app: "A",
                host: "h",
                country: "US",
                bytesIn: 3,
                bytesOut: 0
            )
        ]
        let timeline = ActivityTimelineBuilder.build(rows: rows, hours: days)
        #expect(timeline.rows[0].buckets == [7, 3])
    }
}
