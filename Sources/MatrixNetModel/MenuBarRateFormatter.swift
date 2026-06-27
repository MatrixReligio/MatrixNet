import Foundation

/// Compact throughput formatting for the menu-bar title, where horizontal space
/// is scarce and the text must not wrap or visibly jitter as the numbers change.
///
/// Renders a single short figure per direction (e.g. `1.7M`, `820K`, `15K`,
/// `900B`) and a combined `↓ … ↑ …` form. Pure functions with no shared state,
/// so trivially `Sendable` under Swift 6.
public enum MenuBarRateFormatter {
    private static let units = ["B", "K", "M", "G", "T"]

    /// A short, single-token rate (binary scaled). Idle rates (< 1 B/s) render as
    /// an em dash. Values below ten in their unit keep one decimal; larger values
    /// drop it to stay narrow.
    public static func shortRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "—" }
        var scaled = bytesPerSecond
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        let number = (scaled >= 10 || unit == 0)
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled)
        return number + units[unit]
    }

    /// The combined down/up form shown in the menu bar, e.g. `↓ 1.7M ↑ 820K`.
    public static func compact(in bytesIn: Double, out bytesOut: Double) -> String {
        "↓ \(shortRate(bytesIn)) ↑ \(shortRate(bytesOut))"
    }
}
