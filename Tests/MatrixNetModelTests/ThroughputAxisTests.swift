import Foundation
import Testing
@testable import MatrixNetModel

@Suite("ThroughputAxis")
struct ThroughputAxisTests {
    private let now = Date(timeIntervalSince1970: 10000)

    @Test("the latest sample is zero seconds ago")
    func zeroAtNow() {
        #expect(ThroughputAxis.secondsAgo(of: now, relativeTo: now) == 0)
    }

    @Test("an earlier sample reports its positive age in seconds")
    func positiveAge() {
        let earlier = now.addingTimeInterval(-15)
        #expect(ThroughputAxis.secondsAgo(of: earlier, relativeTo: now) == 15)
    }

    @Test("fractional ages round to the nearest second")
    func rounding() {
        #expect(ThroughputAxis.secondsAgo(of: now.addingTimeInterval(-14.6), relativeTo: now) == 15)
        #expect(ThroughputAxis.secondsAgo(of: now.addingTimeInterval(-14.4), relativeTo: now) == 14)
    }

    @Test("a sample newer than now is clamped to zero, never negative")
    func clampedFuture() {
        #expect(ThroughputAxis.secondsAgo(of: now.addingTimeInterval(5), relativeTo: now) == 0)
    }

    @Test("tick dates anchor now on the right edge")
    func ticksAnchorNow() {
        let ticks = ThroughputAxis.tickDates(latest: now, window: 60, count: 5)
        #expect(ticks.count == 5)
        // Oldest first, so the last tick is exactly now (the right edge).
        #expect(ticks.last == now)
        #expect(ticks.first == now.addingTimeInterval(-60))
    }

    @Test("tick dates are evenly spaced across the window")
    func ticksEvenlySpaced() {
        let ticks = ThroughputAxis.tickDates(latest: now, window: 60, count: 5)
        let agos = ticks.map { ThroughputAxis.secondsAgo(of: $0, relativeTo: now) }
        // 60s window in 5 ticks → 15s apart, oldest first.
        #expect(agos == [60, 45, 30, 15, 0])
    }

    @Test("degenerate counts fall back to a single now tick")
    func degenerateCount() {
        #expect(ThroughputAxis.tickDates(latest: now, window: 60, count: 1) == [now])
        #expect(ThroughputAxis.tickDates(latest: now, window: 0, count: 5) == [now])
    }

    // MARK: - Clock label (24-hour, locale-independent)

    private let utc = TimeZone.gmt

    @Test("midnight reads as 00:mm:ss, not 12-hour 上午12")
    func midnightIsZeroHour() {
        // 1970-01-01 00:10:49 UTC.
        let date = Date(timeIntervalSince1970: 10 * 60 + 49)
        #expect(ThroughputAxis.clockLabel(for: date, timeZone: utc) == "00:10:49")
    }

    @Test("afternoon uses the 24-hour hour, never AM/PM")
    func afternoonIsTwentyFourHour() {
        // 1970-01-01 13:05:09 UTC.
        let date = Date(timeIntervalSince1970: TimeInterval(13 * 3600 + 5 * 60 + 9))
        #expect(ThroughputAxis.clockLabel(for: date, timeZone: utc) == "13:05:09")
    }

    @Test("noon reads as 12:00:00")
    func noonIsTwelve() {
        let date = Date(timeIntervalSince1970: TimeInterval(12 * 3600))
        #expect(ThroughputAxis.clockLabel(for: date, timeZone: utc) == "12:00:00")
    }
}
