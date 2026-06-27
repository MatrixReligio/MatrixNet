# Always-On Agent · Dashboard · Globe — Implementation Plan

> **For agentic workers:** TDD task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship three notarized releases — always-on agent (0.1.8), Overview
dashboard redesign (0.1.9), Globe map (0.1.10) — per
`docs/superpowers/specs/2026-06-27-always-on-dashboard-globe-design.md`.

**Architecture:** Extract pure logic into testable units (formatters, policies,
ring buffer, stats, projection/geometry); assemble SwiftUI views + macOS app
lifecycle glue from those units. New SPM module `MatrixNetMap`. CI is the
canonical build/sign/notarize/release path.

**Tech Stack:** SwiftUI (macOS 26), Swift 6 strict concurrency, Swift Testing,
Swift Charts, SMAppService, UserNotifications, AppKit lifecycle, XcodeGen/SPM.

## Global Constraints

- Passive / zero-conflict; no NetworkExtension; **no new outbound network except
  own release assets** (Globe map is bundled/offline — no map tiles).
- 8-language localization for every new string (en, zh-Hans, zh-Hant, ja, ko, fr,
  de, es). Public docs/DocC/comments English; user comms Chinese.
- `swiftlint --strict` + `swiftformat` clean; full Swift Testing suite green.
- Docs (README/CHANGELOG/NOTICE/DocC) synced before every commit.
- Version source = `project.yml info.properties` (App + Widget blocks); bump both.
- Commits carry no Claude authorship.
- **Verify risky APIs against current docs before coding** (context7 / Apple /
  web) — do not guess.

---

## RELEASE 0.1.8 — Always-On Agent

### Task 1: App lifecycle — engine runs for the process, not the window

**Files:** Create `App/Sources/AppDelegate.swift`; Modify
`App/Sources/MatrixNetApp.swift`.

**Interfaces:** Produces app-owned `AppModel`/`PacketCaptureModel`/
`UpdateController` injected into Window + MenuBarExtra; engine started in
`applicationDidFinishLaunching`.

- [ ] Verify (context7/Apple): `@NSApplicationDelegateAdaptor` + `App` scene
  ownership patterns on macOS 26; `applicationShouldTerminateAfterLastWindowClosed`.
- [ ] Move `model.start()` + `ProxyInfo.refresh()` + GeoIP/Threat `updateIfNeeded`
  into `AppDelegate.applicationDidFinishLaunching`. Hold models on the delegate;
  expose to SwiftUI via `@NSApplicationDelegateAdaptor` + `.environment`.
- [ ] `applicationShouldTerminateAfterLastWindowClosed` → `false`.
- [ ] Build; manual smoke: close window → menu bar persists, snapshot keeps being
  written (widget stays fresh); Quit works.
- [ ] Commit.

### Task 2: `Preferences` store (TDD)

**Files:** Create `App/Sources/Preferences.swift`,
`Tests/.../PreferencesTests` (App-level test target if present, else a pure
helper in a tested module).

**Interfaces:** Produces `Preferences` with typed keys over an injected
`UserDefaults`; consumed by SettingsView, lifecycle, notifier.

- [ ] **Failing test:** defaults — `launchAtLogin=false`, `runInBackground=false`,
  `threatNotificationsEnabled=false`, `historyRetentionDays=30` on a fresh
  `UserDefaults(suiteName: UUID)`.
- [ ] Run → fails.
- [ ] Implement `Preferences` (typed get/set over injected defaults; App Group
  suite in production).
- [ ] **Failing test:** set→get round-trip for each key persists.
- [ ] Implement; run → pass.
- [ ] Commit.

### Task 3: `LoginItemController` (TDD status mapping)

**Files:** Create `App/Sources/LoginItemController.swift`, tests.

**Interfaces:** `protocol LoginItemManaging { var isEnabled: Bool { get }; func
enable() throws; func disable() throws }`; `SMAppServiceLoginItem` conforms.
`LoginItemController(manager:)` exposes `isEnabled` + `setEnabled(_:)`.

- [ ] Verify (Apple/context7): `SMAppService.mainApp` register/unregister + status
  semantics for a Developer-ID app in /Applications.
- [ ] **Failing test:** with a fake manager, `setEnabled(true)` calls `enable()`;
  `isEnabled` reflects fake; error surfaces.
- [ ] Implement controller + fake; run → pass.
- [ ] Implement `SMAppServiceLoginItem` (status→Bool: `.enabled` true; others
  false) — verified by reasoning (real service not unit-tested).
- [ ] Commit.

### Task 4: `activationPolicy` mapping (TDD) + apply

**Files:** Create `App/Sources/ActivationPolicy.swift`, tests; wire in
`AppDelegate`/`MatrixNetApp`.

- [ ] **Failing test:** `activationPolicy(runInBackground: true) == .accessory`;
  `false == .regular`.
- [ ] Implement; run → pass.
- [ ] Apply at launch + on toggle via `NSApp.setActivationPolicy`; menu bar gains
  "Open MatrixNet" + "Quit". Manual smoke.
- [ ] Commit.

### Task 5: `MenuBarRateFormatter` (TDD) + menu-bar label

**Files:** Create `App/Sources/MenuBarRateFormatter.swift`, tests; modify
`MatrixNetApp.swift` (label-based `MenuBarExtra`).

- [ ] Verify (Apple/context7): label-based `MenuBarExtra` live updates with
  `@Observable` on macOS 26.
- [ ] **Failing tests:** `compact(in:out:)` → idle `"↓ — ↑ —"`; `1700`/`1600` →
  stable short `"↓ 1.7K ↑ 1.6K"` style; MB/GB scaling; fixed-width (no wrap).
- [ ] Implement formatter; run → pass.
- [ ] Switch `MenuBarExtra` to label initializer reading the model; manual smoke.
- [ ] Commit.

### Task 6: `ThreatNotificationPolicy` (TDD) + `ThreatNotifier`

**Files:** Create `App/Sources/ThreatNotifier.swift` (+ policy), tests; hook into
`AppModel` publish tick.

**Interfaces:** `ThreatNotificationPolicy.shouldNotify(key:, now:) -> Bool` with
per-key dedup + throttle window (inject clock).

- [ ] Verify (Apple/context7): `UNUserNotificationCenter` authorization + delivery
  for notarized non-sandboxed Developer-ID app; required Info.plist keys.
- [ ] **Failing tests:** first key notifies; same key within window suppressed;
  new key notifies; after window elapses re-notifies; global min-gap honored.
- [ ] Implement policy; run → pass.
- [ ] Implement `ThreatNotifier` (auth on enable; post on policy yes) gated by
  `Preferences.threatNotificationsEnabled`; drive from publish tick using existing
  threat set. Manual smoke.
- [ ] Commit.

### Task 7: `SettingsView` (General / Updates / Data)

**Files:** Create `App/Sources/SettingsView.swift`; modify `MatrixNetApp.swift`
(`Settings` scene).

- [ ] Build the `TabView` binding to `Preferences` (`@AppStorage` App Group suite);
  General: launch-at-login (Task 3), background mode (Task 4), threat
  notifications (Task 6); Updates: automatic-check toggle (Sparkle); Data:
  GeoIP/Threat last-checked + Check-now, history retention.
- [ ] Wire toggles to controllers. Manual smoke (Cmd-,).
- [ ] Commit.

### Task 8: 0.1.8 finalize

- [ ] Localize all new strings into 8 languages (`.xcstrings`); run
  `scripts/check-localizations.py`.
- [ ] `swiftformat .` + `swiftlint --strict` clean; full test suite green.
- [ ] Update README (always-on, settings, login item, menu-bar rate, threat
  notifications), CHANGELOG (0.1.8), DocC; NOTICE unchanged.
- [ ] Bump version → 0.1.8 / build 9 in `project.yml info.properties` (App +
  Widget) and `settings.base`.
- [ ] `xcodegen generate`; CI Release; verify appcast `sparkle:version`/short
  string at the latest feed.
- [ ] Local Developer-ID install + `killall MatrixNetWidget chronod`; verify
  widget stays fresh with window closed.
- [ ] Review round (read diffs, fix issues). Mark tasks #50–#56 done.

---

## RELEASE 0.1.9 — Overview Dashboard (to be detailed at wave start)

- **T1 `ThroughputHistory` ring buffer (TDD)** — capacity cap, eviction, snapshot.
- **T2 `OverviewStats` (TDD)** — session total, active app count, countries
  reached, proxy share over `[Connection]` + GeoIP/Proxy lookups.
- **T3 aggregations (TDD)** — `protocolMix`, `destinationCountries` (flag+share).
- **T4 `OverviewView` redesign** — Swift Charts area chart (verify donut/sector
  mark API), KPI strip, protocol donut, country mini-bar, upgraded Top Talkers.
- **T5 finalize** — localize 8, lint/tests, docs (README/CHANGELOG/DocC), bump →
  0.1.9/10, CI release, local verify, review.

## RELEASE 0.1.10 — Globe Map (to be detailed at wave start)

- **T1 dataset** — `Tools/MapConvert` (Natural Earth 1:110m → land bitset +
  centroids, TDD geometry), `scripts/build-worldmap.sh`, commit `worldmap.dat`.
- **T2 `MatrixNetMap` module (TDD)** — `WorldMap` loader,
  `EquirectangularProjection`, `centroid(forCountry:)`, `arcPath`, `nodeRadius`.
- **T3 `GlobeView`** — dotted real-world base, multi-layer glow arcs + comet
  (`TimelineView`), nodes/home/threat pulses, brand palette.
- **T4 interactions + nav** — Live/History + Threats-only + chips, destinations
  list, hover tooltip, `RootView.Section.map`.
- **T5 finalize** — localize 8, lint/tests, docs incl. **Natural Earth NOTICE**,
  bump → 0.1.10/11, CI release, local verify, review.

## Self-review

Spec coverage: every design section maps to a task. No placeholders in 0.1.8
(0.1.9/0.1.10 intentionally outlined, detailed at their wave). Type names
consistent with the design doc. Risky APIs flagged with explicit verify steps.
