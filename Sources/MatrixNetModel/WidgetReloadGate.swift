import Foundation

/// Decides when the app should nudge WidgetKit to reload the desktop widget's
/// timeline.
///
/// WidgetKit caps a frequently-viewed widget at roughly 40–70 background
/// timeline refreshes per rolling 24-hour window. App-initiated reloads
/// (`WidgetCenter.reloadAllTimelines()`) are **exempt from that budget only
/// while the containing app is in the foreground** (see Apple's "Keeping a
/// widget up to date"). So the gate nudges only in the foreground, throttled;
/// while backgrounded it stays silent and lets the widget's own `.after`
/// timeline policy age the data within budget. Calling reload from the
/// background — as earlier versions did on every write — burns the daily
/// budget within minutes and then freezes the widget for the rest of the window.
public struct WidgetReloadGate {
    /// Minimum spacing between foreground reloads.
    public let minInterval: TimeInterval

    public init(minInterval: TimeInterval = 10) {
        self.minInterval = minInterval
    }

    /// Whether a reload should fire now. Reloads only in the foreground and only
    /// once `minInterval` has elapsed since the previous reload.
    public func shouldReload(isForeground: Bool, now: Date, lastReload: Date) -> Bool {
        guard isForeground else { return false }
        return now.timeIntervalSince(lastReload) >= minInterval
    }
}
