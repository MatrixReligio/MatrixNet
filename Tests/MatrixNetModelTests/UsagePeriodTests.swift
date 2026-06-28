import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsagePeriod")
struct UsagePeriodTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    // 2026-06-15 10:30:00 UTC
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10, minute: 30)) ?? .distantPast
    }

    @Test("today starts at local midnight and ends at now")
    func today() {
        let range = UsagePeriod.today.range(now: now, calendar: cal)
        #expect(range.start == cal.date(from: DateComponents(year: 2026, month: 6, day: 15)))
        #expect(range.end == now)
    }

    @Test("last 7 days spans 7 days back to now")
    func last7() {
        let range = UsagePeriod.last7Days.range(now: now, calendar: cal)
        #expect(range.start == cal.date(byAdding: .day, value: -7, to: now))
        #expect(range.end == now)
    }

    @Test("a cycle reset day earlier this month starts on that day")
    func cycleThisMonth() {
        let range = UsagePeriod.currentCycle(resetDay: 5).range(now: now, calendar: cal)
        #expect(range.start == cal.date(from: DateComponents(year: 2026, month: 6, day: 5)))
    }

    @Test("a cycle reset day later than today rolls back to last month")
    func cyclePrevMonth() {
        let range = UsagePeriod.currentCycle(resetDay: 20).range(now: now, calendar: cal)
        #expect(range.start == cal.date(from: DateComponents(year: 2026, month: 5, day: 20)))
    }

    @Test("a reset day past the month length clamps to the last valid day")
    func cycleClamp() {
        // now = Feb 15 2026; resetDay 31 → Feb has 28 days in 2026, but the
        // previous cycle anchor is Jan 31 (January has 31 days).
        let feb = cal.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 9)) ?? .distantPast
        let range = UsagePeriod.currentCycle(resetDay: 31).range(now: feb, calendar: cal)
        #expect(range.start == cal.date(from: DateComponents(year: 2026, month: 1, day: 31)))
    }

    @Test("trend granularity is hourly for today, daily otherwise")
    func granularity() {
        #expect(UsagePeriod.today.trendGranularity == .hour)
        #expect(UsagePeriod.last30Days.trendGranularity == .day)
    }
}
