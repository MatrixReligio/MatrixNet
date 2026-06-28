# New-Destination Alerts Implementation Plan

> REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Notify (opt-in, non-blocking, rate-limited) when a known app first reaches a country it has never reached before.

**Architecture:** A persistent per-app baseline of (app, country). A pure detector classifies each active connection as known / learning (15-min per-app window) / alert. AppModel records non-known destinations and fires a notifier on `.alert` when the preference is on.

**Tech Stack:** Swift 6, Swift Testing, SwiftData, UserNotifications.

## Global Constraints
- Swift 6 strict concurrency; zero warnings; SwiftLint --strict + SwiftFormat pass.
- TDD first. English code/comments; commits NO Claude authorship. 8-language localization; check-localizations passes. Passive; never blocks.

---

## Task 1: NewDestinationDetector (pure)
**Files:** Create `Sources/MatrixNetModel/NewDestinationDetector.swift`; Test `Tests/MatrixNetModelTests/NewDestinationDetectorTests.swift`
**Produces:** `enum DestinationVerdict: Sendable, Equatable { case known, learning, alert }`; `enum NewDestinationDetector { static func classify(country: String, knownCountries: Set<String>, appFirstSeen: Date?, now: Date, learningWindow: TimeInterval) -> DestinationVerdict }`

- [ ] Test (RED):
```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("NewDestinationDetector")
struct NewDestinationDetectorTests {
    private let now = Date(timeIntervalSince1970: 100_000)
    private func classify(_ country: String, known: Set<String>, firstSeen: Date?) -> DestinationVerdict {
        NewDestinationDetector.classify(country: country, knownCountries: known,
            appFirstSeen: firstSeen, now: now, learningWindow: 900)
    }

    @Test("an empty country is ignored") func empty() {
        #expect(classify("", known: [], firstSeen: nil) == .known)
    }
    @Test("a known country does not alert") func known() {
        #expect(classify("US", known: ["US"], firstSeen: now.addingTimeInterval(-100_000)) == .known)
    }
    @Test("a brand-new app only learns") func newApp() {
        #expect(classify("US", known: [], firstSeen: nil) == .learning)
    }
    @Test("within the learning window only learns") func learning() {
        #expect(classify("CN", known: ["US"], firstSeen: now.addingTimeInterval(-300)) == .learning)
    }
    @Test("a new country past the window alerts") func alerts() {
        #expect(classify("CN", known: ["US"], firstSeen: now.addingTimeInterval(-1000)) == .alert)
    }
}
```
- [ ] Run `swift test --filter NewDestinationDetector` → fails.
- [ ] Implement:
```swift
import Foundation

public enum DestinationVerdict: Sendable, Equatable { case known, learning, alert }

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
```
- [ ] Run → pass. Commit "Add new-destination detector".

## Task 2: DestinationBaselineStore (SwiftData)
**Files:** Create `Sources/MatrixNetStore/KnownDestinationRecord.swift`, `Sources/MatrixNetStore/DestinationBaselineStore.swift`; Test `Tests/MatrixNetStoreTests/DestinationBaselineStoreTests.swift`
**Produces:**
- `@Model final class KnownDestinationRecord { var app: String; var country: String; var firstSeen: Date }`
- `struct AppBaseline: Sendable { var countries: Set<String>; var firstSeen: Date }`
- `@MainActor final class DestinationBaselineStore { init(container:); static func inMemory() throws; static func persistent() throws; func load() throws -> [String: AppBaseline]; func record(app: String, country: String, at: Date) throws }`

- [ ] Test (RED):
```swift
import Foundation
import Testing
@testable import MatrixNetStore

@MainActor
@Suite("DestinationBaselineStore")
struct DestinationBaselineStoreTests {
    @Test("records dedupe by app+country and load aggregates per app") func recordsAndLoads() throws {
        let store = try DestinationBaselineStore.inMemory()
        try store.record(app: "A", country: "US", at: Date(timeIntervalSince1970: 10))
        try store.record(app: "A", country: "US", at: Date(timeIntervalSince1970: 20)) // dup ignored
        try store.record(app: "A", country: "DE", at: Date(timeIntervalSince1970: 30))
        try store.record(app: "B", country: "JP", at: Date(timeIntervalSince1970: 40))
        let baseline = try store.load()
        #expect(baseline["A"]?.countries == ["US", "DE"])
        #expect(baseline["A"]?.firstSeen == Date(timeIntervalSince1970: 10)) // earliest
        #expect(baseline["B"]?.countries == ["JP"])
    }
}
```
- [ ] Run → fails.
- [ ] Implement (mirror UsageStore): record fetches existing by app+country (fetchLimit 1), inserts if absent; load fetches all, folds into `[String: AppBaseline]` (union countries, min firstSeen).
- [ ] Run → pass. Commit "Add destination baseline store".

## Task 3: Preference
**Files:** Modify `Sources/MatrixNetModel/Preferences.swift`; add a case to `Tests/MatrixNetModelTests/PreferencesTests.swift`
**Produces:** `Preferences.newDestinationAlertsEnabled: Bool` (default false); `Key.newDestinationAlertsEnabled = "pref.newDestinationAlertsEnabled"`.

- [ ] Test (RED): add `#expect(prefs.newDestinationAlertsEnabled == false)` to the defaults test.
- [ ] Run → fails.
- [ ] Implement: add the Key case and a bool-backed property (use the existing `bool(_:default:)`/`setBool` helpers).
- [ ] Run → pass. Commit "Add new-destination-alerts preference".

## Task 4: NewDestinationNotifier
**Files:** Create `App/Sources/NewDestinationNotifier.swift`
**Consumes:** `ThreatNotificationPolicy` (rate limiting), UserNotifications.

- [ ] (No unit test — UNUserNotificationCenter; mirrors ThreatNotifier which is untested.) Implement `@MainActor final class NewDestinationNotifier` with its own `ThreatNotificationPolicy`, `requestAuthorizationIfNeeded()`, and `notify(app: String, country: String, host: String?, now: Date)` that posts only when `policy.shouldNotify(key: app + "\u{1F}" + country, now: now)`. Title `String(localized: "New destination")`; body `String(localized: "\(app) reached \(country) for the first time")`.
- [ ] Build app → succeeds. Commit "Add new-destination notifier".

## Task 5: AppModel orchestration
**Files:** Modify `App/Sources/AppModel.swift`
**Consumes:** `DestinationBaselineStore`, `NewDestinationDetector`, `NewDestinationNotifier`, `GeoIP.country`, `Preferences.newDestinationAlertsEnabled`.

- [ ] Add stored props: `private let destinationBaselineStore = try? DestinationBaselineStore.persistent()`, `private var knownDestinations: [String: AppBaseline] = [:]`, `var newDestinationNotifier: NewDestinationNotifier?` (set by AppDelegate like threatNotifier). In `init`, load the baseline: `knownDestinations = (try? destinationBaselineStore?.load()) ?? [:]`.
- [ ] In `publish`, after computing `connections`, add a `detectNewDestinations(now:)` pass: for each active connection with a resolvable country, classify against `knownDestinations`; on non-`.known`, record to store + update in-memory (`knownDestinations[app]`); on `.alert` with the preference on, call `newDestinationNotifier?.notify(...)`. Localized country name for display: `Locale.current.localizedString(forRegionCode: country) ?? country`.
- [ ] Wire `newDestinationNotifier` in `App/Sources/AppDelegate.swift` next to `threatNotifier`.
- [ ] Build app + `swift test` → green. Commit "Detect and alert on new destinations in AppModel".

## Task 6: Settings toggle + localization
**Files:** Modify `App/Sources/SettingsView.swift`, `App/Resources/Localizable.xcstrings`
- [ ] Add a Toggle bound to `@AppStorage(Preferences.Key.newDestinationAlertsEnabled.rawValue, store: SharedMetricsStore.sharedDefaults)` in GeneralSettings, with `.onChange` calling `model.newDestinationNotifier?.requestAuthorizationIfNeeded()` when enabled, and a footer. Localize the toggle title, footer, and the notifier's title/body keys into all 8 languages. New keys: `"Notify about new destinations"`, the footer, `"New destination"`, `"%@ reached %@ for the first time"` (verify the exact key SwiftUI generates for the interpolated body — `String(localized: "\(app) reached \(country) for the first time")` → `"%@ reached %@ for the first time"`).
- [ ] `python3 scripts/check-localizations.py` → passes. swiftformat, swiftlint --strict, build → clean. Commit "Add new-destination settings toggle and localizations".

## Task 7: Docs + release (0.1.24)
- [ ] Bump project.yml → 0.1.24 / build 25 (×6) + xcodegen.
- [ ] CHANGELOG `## [0.1.24]` Added; README feature bullet (8 languages).
- [ ] Full gate (format/lint/test/loc) + Release build; commit (no Claude authorship), push, `gh workflow run release.yml -f version=v0.1.24`, watch, verify appcast `sparkle:version == 25`, local install.

## Self-Review
- Spec §3.1→T1, §3.2→T2, §3.5 pref→T3, §3.4 notifier→T4, §3.3→T5, settings/loc→T6, docs/release→T7. Covered.
- Types: `DestinationVerdict`/`classify` T1→T5; `AppBaseline`/`DestinationBaselineStore` T2→T5; `newDestinationAlertsEnabled` T3→T5,T6; `NewDestinationNotifier.notify` T4→T5. Consistent.
