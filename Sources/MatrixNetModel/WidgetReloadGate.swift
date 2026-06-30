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
    /// Maximum spacing between metrics-file writes. The widget only reads the file
    /// when its timeline refreshes — at most every `minInterval` in the foreground
    /// (each reload), and roughly every 30 minutes in the background. Writing on
    /// every ~1s tick wears the disk for snapshots nobody reads, so writes are
    /// gated to a reload (foreground) or this slow heartbeat (background), sized a
    /// bit under the widget's ~30-min background cadence so a refresh still finds
    /// fresh-enough data.
    public let heartbeatInterval: TimeInterval

    public init(minInterval: TimeInterval = 60, heartbeatInterval: TimeInterval = 1200) {
        self.minInterval = minInterval
        self.heartbeatInterval = heartbeatInterval
    }

    /// Whether a reload should fire now. Reloads only in the foreground and only
    /// once `minInterval` has elapsed since the previous reload.
    public func shouldReload(isForeground: Bool, now: Date, lastReload: Date) -> Bool {
        guard isForeground else { return false }
        return now.timeIntervalSince(lastReload) >= minInterval
    }

    /// Whether to (over)write the shared metrics file and/or nudge a reload now.
    /// Write only when the widget will actually read it: right before a foreground
    /// reload, or once the background heartbeat has elapsed. This keeps the widget
    /// as fresh as WidgetKit allows without touching the disk every tick.
    public func decide(isForeground: Bool, now: Date, lastReload: Date, lastWrite: Date) -> WidgetPublishDecision {
        let reload = shouldReload(isForeground: isForeground, now: now, lastReload: lastReload)
        let write = reload || now.timeIntervalSince(lastWrite) >= heartbeatInterval
        return WidgetPublishDecision(write: write, reload: reload)
    }
}

/// The two independent actions the app may take on a refresh tick: persist a new
/// metrics snapshot for the widget, and/or nudge WidgetKit to reload its timeline.
public struct WidgetPublishDecision: Equatable, Sendable {
    public let write: Bool
    public let reload: Bool

    public init(write: Bool, reload: Bool) {
        self.write = write
        self.reload = reload
    }
}
