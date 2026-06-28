import Foundation

/// Maps timestamps to the start of their hour bucket.
public enum UsageBucketing {
    /// The start of the hour containing `date`, in `calendar`'s time zone.
    public static func hourStart(of date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: parts) ?? date
    }
}
