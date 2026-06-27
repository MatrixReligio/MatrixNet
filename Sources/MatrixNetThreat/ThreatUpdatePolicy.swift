import Foundation

/// Pure, testable policy for the threat-list auto-updater. The actual download
/// and file I/O live in the app; this type holds only the decisions so they can
/// be unit-tested without the network or filesystem.
public enum ThreatUpdatePolicy {
    /// IPsum rebuilds its lists daily; a weekly check keeps the local copy
    /// reasonably fresh without frequent downloads.
    public static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether an update check is due. A `nil` `lastChecked` always returns true.
    public static func shouldCheck(
        now: Date,
        lastChecked: Date?,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Validates that downloaded bytes are a well-formed, non-empty threat
    /// database before they replace the current one.
    public static func isValidDatabase(_ data: Data) -> Bool {
        guard let database = ThreatDatabase(data: data) else { return false }
        return !database.isEmpty
    }
}
