import Foundation
import MatrixNetModel
import UserNotifications

/// Posts a system notification when a known app first reaches a country it has
/// never reached before. Advisory only — MatrixNet never blocks. Gated by a
/// preference and rate-limited by `ThreatNotificationPolicy` so a burst of new
/// destinations does not flood Notification Center.
@MainActor
final class NewDestinationNotifier {
    private var policy = ThreatNotificationPolicy()
    private var authorizationRequested = false

    /// Ask for notification authorization the first time the feature is enabled.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a new-destination notification if the rate-limit policy allows it.
    /// `country` is the human-readable region name; `host` is the destination that
    /// triggered it, when known.
    func notify(app: String, country: String, host: String?, now: Date = Date()) {
        guard policy.shouldNotify(key: app + "\u{1F}" + country, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "New destination")
        if let host {
            content.body = String(localized: "\(app) reached \(country) for the first time (\(host)).")
        } else {
            content.body = String(localized: "\(app) reached \(country) for the first time.")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
