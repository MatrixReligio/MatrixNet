import Foundation
import MatrixNetModel
import UserNotifications

/// Posts a system notification when an active connection reaches a threat-listed
/// address. Advisory only — MatrixNet never blocks. Gated by a preference and
/// rate-limited by `ThreatNotificationPolicy` so a long-lived flow or a burst of
/// flows does not flood Notification Center.
@MainActor
final class ThreatNotifier {
    /// One active connection reaching a flagged address.
    struct Hit {
        let app: String
        let ip: String
        let host: String?
    }

    private var policy = ThreatNotificationPolicy()
    private var authorizationRequested = false

    /// Ask for notification authorization the first time the feature is enabled.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluate the current active threat connections and post notifications for
    /// the ones the policy allows. Driven from the ~1 s publish tick.
    func evaluate(_ hits: [Hit], enabled: Bool, now: Date = Date()) {
        guard enabled, !hits.isEmpty else { return }
        requestAuthorizationIfNeeded()
        for hit in hits where policy.shouldNotify(key: hit.app + "\u{1F}" + hit.ip, now: now) {
            post(hit)
        }
    }

    private func post(_ hit: Hit) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Threat connection detected")
        content.body = String(
            localized: "\(hit.app) is connected to \(hit.host ?? hit.ip), a flagged address."
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
