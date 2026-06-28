import Foundation

/// Typed access to MatrixNet's user preferences, backed by a `UserDefaults`
/// store (the shared App Group suite in production, an isolated suite in tests).
///
/// Setters are `nonmutating` because the backing store is a reference type, so a
/// single `let prefs` can both read and write. The same key strings are exposed
/// as `Preferences.Key` so SwiftUI `@AppStorage` bindings stay in sync with the
/// non-UI readers (app lifecycle, threat notifier).
public struct Preferences {
    /// Persisted preference keys (raw values are the `UserDefaults` keys).
    public enum Key: String, Sendable {
        case launchAtLogin = "pref.launchAtLogin"
        case runInBackground = "pref.runInBackground"
        case threatNotificationsEnabled = "pref.threatNotificationsEnabled"
        case historyRetentionDays = "pref.historyRetentionDays"
        case homeRegion = "pref.homeRegion"
        case showDomains = "pref.showDomains"
        case usageRetentionDays = "pref.usageRetentionDays"
        case billingCycleResetDay = "pref.billingCycleResetDay"
        case newDestinationAlertsEnabled = "pref.newDestinationAlertsEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func bool(_ key: Key, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private func setBool(_ value: Bool, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Whether the app registers itself as a login item (launch at login).
    public var launchAtLogin: Bool {
        get { bool(.launchAtLogin, default: false) }
        nonmutating set { setBool(newValue, .launchAtLogin) }
    }

    /// Whether the app runs as a menu-bar-only agent (no Dock icon).
    public var runInBackground: Bool {
        get { bool(.runInBackground, default: false) }
        nonmutating set { setBool(newValue, .runInBackground) }
    }

    /// Whether to post a system notification when an active connection reaches a
    /// threat-listed address.
    public var threatNotificationsEnabled: Bool {
        get { bool(.threatNotificationsEnabled, default: false) }
        nonmutating set { setBool(newValue, .threatNotificationsEnabled) }
    }

    /// How many days of connection history to retain (0 = keep forever).
    public var historyRetentionDays: Int {
        get { defaults.object(forKey: Key.historyRetentionDays.rawValue) as? Int ?? 30 }
        nonmutating set { defaults.set(newValue, forKey: Key.historyRetentionDays.rawValue) }
    }

    /// Whether to show resolved domain names instead of raw IPs where a name is
    /// known (Connections, Packets, Map). Defaults to on.
    public var showDomains: Bool {
        get { bool(.showDomains, default: true) }
        nonmutating set { setBool(newValue, .showDomains) }
    }

    /// Whether to post a notification when a known app first reaches a country it
    /// has never reached before (advisory only — never blocks).
    public var newDestinationAlertsEnabled: Bool {
        get { bool(.newDestinationAlertsEnabled, default: false) }
        nonmutating set { setBool(newValue, .newDestinationAlertsEnabled) }
    }

    /// How many days of per-app usage history to retain.
    public var usageRetentionDays: Int {
        get { defaults.object(forKey: Key.usageRetentionDays.rawValue) as? Int ?? 90 }
        nonmutating set { defaults.set(newValue, forKey: Key.usageRetentionDays.rawValue) }
    }

    /// Day of the month the billing cycle resets on, clamped to 1...28 so it is
    /// valid in every month.
    public var billingCycleResetDay: Int {
        get {
            let raw = defaults.object(forKey: Key.billingCycleResetDay.rawValue) as? Int ?? 1
            return min(28, max(1, raw))
        }
        nonmutating set { defaults.set(min(28, max(1, newValue)), forKey: Key.billingCycleResetDay.rawValue) }
    }

    /// The ISO-2 region used as the Map's "home" anchor, or `nil` to follow the
    /// system region. (The system region can differ from physical location.)
    public var homeRegion: String? {
        get {
            let value = defaults.string(forKey: Key.homeRegion.rawValue) ?? ""
            return value.isEmpty ? nil : value
        }
        nonmutating set {
            defaults.set(newValue ?? "", forKey: Key.homeRegion.rawValue)
        }
    }
}
