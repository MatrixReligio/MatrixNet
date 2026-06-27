import Foundation

/// Time-axis math for the live throughput chart. "Now" (the latest sample) is
/// anchored at the right edge, and earlier samples are labelled by their
/// positive age in seconds — so the axis reads `60s … 15s … now` left to right,
/// without negative signs that collide with the y-axis baseline.
public enum ThroughputAxis {
    /// Whole seconds between `date` and `latest` ("now"), rounded to the nearest
    /// second and clamped to zero so a sample at or after `latest` reads as `now`.
    public static func secondsAgo(of date: Date, relativeTo latest: Date) -> Int {
        max(0, Int(latest.timeIntervalSince(date).rounded()))
    }

    /// Evenly spaced tick dates spanning `window` seconds, anchored so the last
    /// element is exactly `latest` (the right edge / "now"). Returned oldest
    /// first. Degenerate inputs collapse to a single `latest` tick.
    public static func tickDates(latest: Date, window: TimeInterval, count: Int) -> [Date] {
        guard count >= 2, window > 0 else { return [latest] }
        let step = window / Double(count - 1)
        return (0 ..< count).map { index in
            latest.addingTimeInterval(-window + step * Double(index))
        }
    }

    /// A zero-padded 24-hour wall-clock label (`HH:mm:ss`) for `date` in the
    /// given time zone. Always 24-hour and locale-independent so midnight reads
    /// as `00:10:49` rather than the ambiguous 12-hour `12:10:49 AM`.
    public static func clockLabel(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
