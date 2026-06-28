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

    @Test("places rows by bucket boundaries, not a fixed step (handles uneven grids/DST)")
    func nonUniformGrid() {
        // Gaps 3600 then 7200 — like a daily grid crossing a DST transition.
        let grid = [h0, h0.addingTimeInterval(3600), h0.addingTimeInterval(10800)]
        // A row at h0+7200 falls in bucket 1 (3600 ≤ 7200 < 10800), not bucket 2.
        let mid = UsageRow(
            periodStart: h0.addingTimeInterval(7200),
            app: "A",
            host: "h",
            country: "US",
            bytesIn: 9,
            bytesOut: 0
        )
        let timeline = ActivityTimelineBuilder.build(rows: [mid], hours: grid)
        #expect(timeline.rows[0].buckets == [0, 9, 0])
    }

    @Test("excludes a row at or after the end of the last bucket")
    func atEnd() {
        let endRow = UsageRow(
            periodStart: h0.addingTimeInterval(3 * 3600), // == last bucket start + step
            app: "A",
            host: "h",
            country: "US",
            bytesIn: 99,
            bytesOut: 0
        )
        #expect(ActivityTimelineBuilder.build(rows: [endRow], hours: hours).rows.isEmpty)
    }

    @Test("breaks equal totals by app name ascending")
    func tiebreak() {
        let timeline = ActivityTimelineBuilder.build(
            rows: [row("Zebra", 0, 50), row("Apple", 0, 50)],
            hours: hours
        )
        #expect(timeline.rows.map(\.app) == ["Apple", "Zebra"])
    }
}
