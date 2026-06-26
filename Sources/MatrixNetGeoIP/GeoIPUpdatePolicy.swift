import Foundation

/// Pure, testable policy for the GeoIP auto-updater. The actual download and
/// file I/O live in the app; this type holds only the decisions so they can be
/// unit-tested without the network or filesystem.
public enum GeoIPUpdatePolicy {
    /// DB-IP publishes the Country Lite dataset monthly, so a weekly check is
    /// ample to pick up a new month shortly after it lands.
    public static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether an update check is due. A `nil` `lastChecked` (never checked)
    /// always returns `true`.
    public static func shouldCheck(
        now: Date,
        lastChecked: Date?,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Validates that downloaded bytes are a well-formed, non-empty GeoIP
    /// database before they are allowed to replace the current one. Guards
    /// against truncated downloads or error pages served as `geoip.dat`.
    public static func isValidDatabase(_ data: Data) -> Bool {
        guard let database = GeoIPDatabase(data: data) else { return false }
        return !database.isEmpty
    }
}
