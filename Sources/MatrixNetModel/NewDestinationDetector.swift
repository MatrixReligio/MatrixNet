import Foundation

/// Whether an active connection's destination country is already part of an
/// app's baseline, still being learned, or a genuinely new destination worth an
/// (opt-in, non-blocking) alert.
public enum DestinationVerdict: Sendable, Equatable { case known, learning, alert }

/// Decides whether a destination country is new for an app. A per-app learning
/// window keeps a freshly-seen app (or a multi-country CDN on first run) from
/// flooding alerts: everything is learned silently until the window elapses.
public enum NewDestinationDetector {
    public static func classify(
        country: String,
        knownCountries: Set<String>,
        appFirstSeen: Date?,
        now: Date,
        learningWindow: TimeInterval
    ) -> DestinationVerdict {
        if country.isEmpty || knownCountries.contains(country) { return .known }
        guard let appFirstSeen else { return .learning }
        return now.timeIntervalSince(appFirstSeen) < learningWindow ? .learning : .alert
    }
}
