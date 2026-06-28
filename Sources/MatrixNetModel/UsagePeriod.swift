import Foundation

/// The time resolution used to chart a period's trend.
public enum TrendGranularity: Sendable, Equatable { case hour, day }

/// A selectable reporting window for the Usage tab.
public enum UsagePeriod: Sendable, Equatable {
    case today
    case last7Days
    case last30Days
    case currentCycle(resetDay: Int)

    public var trendGranularity: TrendGranularity {
        switch self {
        case .today: .hour
        default: .day
        }
    }

    public func range(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        switch self {
        case .today:
            (calendar.startOfDay(for: now), now)
        case .last7Days:
            (calendar.date(byAdding: .day, value: -7, to: now) ?? now, now)
        case .last30Days:
            (calendar.date(byAdding: .day, value: -30, to: now) ?? now, now)
        case let .currentCycle(resetDay):
            (Self.cycleStart(resetDay: resetDay, now: now, calendar: calendar), now)
        }
    }

    /// The most recent billing-cycle anchor ≤ now: the reset day this month if it
    /// has already passed, else last month; clamped to each month's length.
    private static func cycleStart(resetDay: Int, now: Date, calendar: Calendar) -> Date {
        let clampedDay = max(1, resetDay)
        func anchor(year: Int, month: Int) -> Date {
            var comps = DateComponents(year: year, month: month, day: 1)
            let monthDate = calendar.date(from: comps) ?? now
            let length = calendar.range(of: .day, in: .month, for: monthDate)?.count ?? 28
            comps.day = min(clampedDay, length)
            return calendar.date(from: comps) ?? now
        }
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 2000
        let month = parts.month ?? 1
        let thisMonth = anchor(year: year, month: month)
        if thisMonth <= now { return thisMonth }
        let previous = month == 1 ? (year: year - 1, month: 12) : (year: year, month: month - 1)
        return anchor(year: previous.year, month: previous.month)
    }
}
