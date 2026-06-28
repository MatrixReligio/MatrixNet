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

    /// Whether to attempt a download now. Downloads when forced, when no usable
    /// database exists yet (ignore the throttle so a fresh or mis-packaged install
    /// self-heals on launch), or when the throttle window has elapsed.
    public static func shouldDownload(
        hasDatabase: Bool,
        force: Bool,
        now: Date,
        lastChecked: Date?,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        if force || !hasDatabase { return true }
        return shouldCheck(now: now, lastChecked: lastChecked, interval: interval)
    }

    /// Whether to record this check time (and throttle the next one). Record on
    /// success, or on failure only when a usable database already exists — an
    /// install with no database keeps retrying every launch until it gets one.
    public static func shouldRecordCheck(succeeded: Bool, hasDatabase: Bool) -> Bool {
        succeeded || hasDatabase
    }
}
