import Foundation

/// Decides *whether* to post a threat-connection notification, so the notifier
/// itself stays a thin shell around `UNUserNotificationCenter`.
///
/// Two guards prevent alert floods:
/// - **Per-key dedup window** — the same `(app, remote IP)` key is not re-alerted
///   until `perKeyWindow` seconds have elapsed (a long-lived flow alerts once).
/// - **Global minimum gap** — at most one notification per `globalMinGap` seconds
///   across all keys, smoothing bursts when many flows light up at once.
///
/// The clock is passed in (`now:`) so the behavior is deterministically testable.
public struct ThreatNotificationPolicy: Sendable {
    public let perKeyWindow: TimeInterval
    public let globalMinGap: TimeInterval

    private var lastByKey: [String: Date] = [:]
    private var lastAny: Date = .distantPast

    public init(perKeyWindow: TimeInterval = 60, globalMinGap: TimeInterval = 3) {
        self.perKeyWindow = perKeyWindow
        self.globalMinGap = globalMinGap
    }

    /// Returns true and records the decision when a notification should fire for
    /// `key` at `now`; returns false (without recording) when suppressed.
    public mutating func shouldNotify(key: String, now: Date) -> Bool {
        if now.timeIntervalSince(lastAny) < globalMinGap { return false }
        if let last = lastByKey[key], now.timeIntervalSince(last) < perKeyWindow { return false }
        lastByKey[key] = now
        lastAny = now
        return true
    }
}
