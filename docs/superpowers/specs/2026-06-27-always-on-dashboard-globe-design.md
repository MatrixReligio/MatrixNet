# Always-On Agent · Dashboard Redesign · Globe Map — Design

**Date:** 2026-06-27
**Status:** Approved (visual mockups reviewed and signed off)

## Goal

Three coordinated capability sets for MatrixNet, shipped as three notarized
releases:

1. **Always-on agent (0.1.8)** — the monitor keeps running (and keeps the widget
   fresh) when the main window is closed, with a Settings window, launch-at-login,
   an optional menu-bar-only (no Dock icon) mode, live throughput in the menu-bar
   title, and system notifications when an active connection reaches a threat IP.
2. **Overview dashboard redesign (0.1.9)** — replace the three-card + bar list with
   a real instrument dashboard: a live throughput chart (Swift Charts), a richer
   KPI strip, protocol mix, destination countries, and an upgraded Top Talkers.
3. **Globe map (0.1.10)** — a new top-level "Map" tab rendering a **real-world**
   dotted world map (Natural Earth 1:110m, public domain) drawn offline with
   SwiftUI Canvas, with glowing great-circle arcs (animated comet heads) from the
   user's location to each active destination, node size by traffic, threat IPs in
   red, plus a live destinations list and hover tooltip.

## Global Constraints (apply to every task)

- **Passive / zero-conflict:** no NetworkExtension, no traffic blocking, no new
  outbound network except the app's own release assets. The Globe map is drawn
  from a **bundled static** dataset — it must NOT fetch map tiles (this is why
  MapKit was rejected).
- **100% native SwiftUI**, latest macOS 26 APIs, Swift 6 strict concurrency.
- **TDD** with Swift Testing; pure logic extracted into testable units.
- **Zero warnings / lint:** `swiftlint --strict` + `swiftformat` clean.
- **Localization into 8 languages** (en, zh-Hans, zh-Hant, ja, ko, fr, de, es) —
  every new user-facing string, no omissions. Public docs / DocC / code comments
  in **English**; user communication in Chinese.
- **Docs synced before every commit:** README / CHANGELOG / NOTICE / DocC updated
  to reflect new features.
- **Version source of truth:** `project.yml` `info.properties`
  (CFBundleShortVersionString / CFBundleVersion), bumped in BOTH the App and
  Widget blocks; CI is the canonical build/sign/notarize/release path.
- **Commits carry no Claude/Claude Code authorship.**

## Existing architecture (relevant parts)

- `App/Sources/MatrixNetApp.swift` — `App` with a single `Window("main")` whose
  `onAppear` calls `model.start()` + dataset refreshes, plus a `MenuBarExtra`
  (`.window` style) hosting `MenuBarView`. **The engine start is bound to the
  window** — this is the root cause of the widget freezing when the window is gone.
- `App/Sources/AppModel.swift` — `@MainActor @Observable`. `start()` spins a 1 s
  refresh task that publishes `connections`, throughput, `topApps`, `threatCount`,
  and writes a `MetricsSnapshot` to the App Group via `SharedMetricsStore`
  (throttled 2 s; WidgetKit reload nudged ≤ every 20 s).
- `App/Sources/RootView.swift` — `NavigationSplitView` sidebar `Section` enum
  (overview / connections / packets / history) → detail views. **Add `.map`.**
- Modules under `Sources/`: Model, Dissection, Pcap, Capture, Store, GeoIP,
  Threat, XPC. **Add `MatrixNetMap`.**
- `MatrixNetGeoIP.GeoIPDatabase` — IPv4 → ISO-2 country (country-only; no
  coordinates). `App/Sources/GeoIP.swift` / `Threat.swift` — App Group wrappers
  with background `updateIfNeeded`. `ProxyDetection` / `ProxyInfo` — proxy/tunnel
  classification. `ConnectionRole` — client/server inference.

---

## Release 0.1.8 — Always-On Agent

### A1. Lifecycle: start the engine at launch, not with the window

**Problem:** `model.start()` runs in `Window.onAppear`; closing the window (or
running with no Dock icon) means the engine — and the widget's data source — can
stop being driven.

**Design:** Introduce an `AppDelegate: NSObject, NSApplicationDelegate` via
`@NSApplicationDelegateAdaptor`. In `applicationDidFinishLaunching` start the
engine and dataset refreshes (moved out of `onAppear`). The `AppModel`,
`PacketCaptureModel`, and `UpdateController` become app-owned (held by the
delegate or the `App` struct) and injected into both the window and the menu bar.
`applicationShouldTerminateAfterLastWindowClosed` returns `false`. The engine and
its snapshot-publishing loop run for the whole process lifetime, so the widget
stays fresh whenever the process lives. Quit remains available (Cmd-Q / menu-bar
"Quit").

**Testable units:** keep `AppModel.start()/stop()` idempotency (existing). New
glue is thin and UI-bound; verify by reasoning + manual smoke. Where logic can be
extracted (e.g. "should the engine be running?") put it in a pure helper.

### A2. Settings window + preferences store

**Design:** Add a `Settings { SettingsView() }` scene (standard Cmd-, window) with
a `TabView`: **General**, **Updates**, **Data**. A `Preferences` type wraps the
App Group `UserDefaults` (`SharedMetricsStore` suite) with typed keys and
defaults; the view binds via `@AppStorage` (App Group suite) so both the app and
(future) widget read the same values.

Preference keys (initial):
- `launchAtLogin: Bool` (A3)
- `runInBackground: Bool` — menu-bar-only / hide Dock icon (A4)
- `threatNotificationsEnabled: Bool` (A5)
- `automaticUpdateChecks: Bool` — bound to Sparkle's existing setting
- Data: shows GeoIP / Threat last-checked + "Check now" buttons; history retention
  selector (off / 7 / 30 / 90 days) read by `HistoryStore`.

**Testable units:** `Preferences` default values and key round-trips (inject a
throwaway `UserDefaults(suiteName:)`), TDD.

### A3. Launch at login

**Design:** `LoginItemController` wrapping `SMAppService.mainApp` with
`register()` / `unregister()` and a `status` → `Bool` mapping. The General tab
toggle calls register/unregister and reflects `.status`. On failure show a
readable message and offer `SMAppService.openSystemSettingsLoginItems()`. Inject a
protocol (`LoginItemManaging`) so the status↔toggle mapping is unit-tested without
touching the real service.

### A4. Background (menu-bar-only) mode — hide Dock icon

**Design:** A pure `func activationPolicy(runInBackground: Bool) -> NSApplication.ActivationPolicy`
(`.accessory` when true, else `.regular`), applied at launch and whenever the
toggle changes via `NSApp.setActivationPolicy(...)`. In `.accessory` mode there is
no Dock icon; the app lives in the menu bar. The `MenuBarExtra` content gets
"Open MatrixNet" (re-opens/forewards the main window and momentarily switches to
`.regular` if needed) and "Quit". TDD the pure mapping.

### A5. Menu-bar title live rate

**Design:** Switch the `MenuBarExtra` to the label-based initializer so the menu
bar shows a compact live rate, e.g. `↓ 1.7M ↑ 1.6M`, next to/instead of the icon.
A pure `MenuBarRateFormatter.compact(in:out:) -> String` produces a stable,
non-jittering short form (fixed width, K/M/G, no wrapping). The label view reads
the observable model so it updates live. TDD the formatter (rounding, units,
zero/idle "—", width stability).

### A6. Threat-connection notifications

**Design:** `ThreatNotifier` posts a `UNUserNotificationCenter` notification when
an active connection reaches a threat IP, gated by `threatNotificationsEnabled`.
Authorization requested lazily on first enable. A pure
`ThreatNotificationPolicy` decides *whether* to notify: dedup by (app, remote IP)
so the same flow doesn't re-alert, and throttle (e.g. ≥ 60 s between notifications
for the same key; global minimum gap) to avoid floods. The notifier is driven from
the existing 1 s publish tick using the already-computed threat set.

**Testable units:** `ThreatNotificationPolicy` — first hit notifies, repeat within
window suppressed, new IP notifies, throttle window honored. TDD with injected
clock.

### 0.1.8 deliverables
8-language localization for all new strings; lint/tests green; README / CHANGELOG
/ NOTICE / DocC updated; version bump; CI notarized release + appcast check; local
Developer-ID install + widget reload verification; ≥ 1 review round.

---

## Release 0.1.9 — Overview Dashboard Redesign (direction 1: chart-hero)

### B1. Throughput history + live chart

**Design:** `ThroughputHistory` — a fixed-capacity ring buffer (≈ 60 samples at
1 Hz) of `(timestamp, inRate, outRate)`, a pure value type appended from the 1 s
tick. `OverviewView` renders it with **Swift Charts** as an area+line chart
(inbound blue / outbound orange gradients, `Theme` colors), current values
overlaid. TDD the ring buffer (capacity cap, eviction order, snapshot for chart).

### B2. Extended KPI metrics

**Design:** Compute and expose on `AppModel` (or a pure `OverviewStats` over
`[Connection]` + lookups): session total (`bytesIn+bytesOut`), active app count
(distinct apps with active connections), **countries reached** (distinct GeoIP
countries among active remotes), threat connections (existing), **proxy share**
(% active connections whose remote `routesThroughProxy`). The KPI strip shows
these per the approved chart-hero layout. TDD the pure stats over fixtures.

### B3. Protocol mix · destination countries · upgraded Top Talkers

**Design:** Pure aggregations over the active connections:
- `protocolMix` → ordered `[(label, share)]` (TLS/QUIC/DNS/TCP/UDP/Other), shown
  as a Swift Charts donut/sector mark.
- `destinationCountries` → top countries by traffic with flag + share, mini bar;
  row links to the Map tab.
- Top Talkers upgraded: icon + name + **flag** + connection count + ↓↑ rate +
  threat/tunnel chips + thin bar (reuse `GeoIP`, `ProxyInfo`, `Threat`).

TDD the aggregation/sorting/share-rounding functions.

### 0.1.9 deliverables
As 0.1.8 (localization, lint/tests, docs, version bump, CI release, local verify,
review).

---

## Release 0.1.10 — Globe Map

### C1. World dataset (real geography, offline, static)

**Source:** **Natural Earth 1:110m** vector data (public domain — "no rights
reserved"), specifically `ne_110m_admin_0_countries` (for country polygons →
centroids) and land geometry (for the dotted base). Mirrored at the
`nvkelso/natural-earth-vector` GitHub repo as GeoJSON.

**Build:** `Tools/MapConvert/main.swift` reads the GeoJSON and emits a compact
binary `App/Resources/worldmap.dat` (committed, static, never auto-updated):
1. **Land dot mask** — rasterize land polygons onto an equirectangular grid
   (≈ 1° resolution, 360×180 → packed bitset, ~8 KB) via point-in-polygon. The
   dotted base draws a dot at each set cell → a *recognizable, real* world map.
2. **Country centroid table** — ISO-2 → (lat, lon) representative point computed
   from each country's largest polygon. ~250 entries.

`scripts/build-worldmap.sh` downloads the source, runs `MapConvert`, writes the
asset. TDD the converter's geometry (point-in-polygon, centroid, binary
round-trip) on small synthetic fixtures.

**Why not auto-update:** coastlines/borders are effectively static; the asset is
bundled once. The *moving* data (which countries you talk to) comes from live
connections + the already-auto-updating GeoIP country DB.

### C2. `MatrixNetMap` module (pure)

**Design:** New SPM module `MatrixNetMap` with pure, `Sendable` functions:
- `WorldMap(data:)` loader → land dot cells + centroid lookup.
- `EquirectangularProjection` — `project(lat,lon, in: CGSize) -> CGPoint` and
  inverse; pure, TDD against known points (equator/prime-meridian, corners, poles
  clamp).
- `centroid(forCountry:) -> Coordinate?`.
- `arcPath(from:to:, in:) -> [CGPoint]` — a raised quadratic/great-circle-ish
  curve sampled to points (apex lifted by distance) for the glowing arc.
- `nodeRadius(forBytes:) -> CGFloat` — log-scaled traffic → radius (clamped).
- "Home" = `Locale.current.region` → ISO-2 → centroid (offline; no geolocation).

TDD all of the above.

### C3. Globe view (rendering)

**Design:** `GlobeView` (App) draws on a dark, warm-tinted canvas card embedded in
the light page:
- Dotted real-world base from the land mask (muted phosphor green).
- Glowing great-circle arcs: multi-layer stroke (wide blurred + thin bright) using
  `Theme.accent`; **comet head** animated along each arc via `TimelineView` phase.
- Destination nodes sized by traffic; **home** white pulse; **threat** red pulse +
  red arc (`Theme.danger`).
- Uses `Canvas`/`TimelineView` for 60 fps-friendly animation; degrades gracefully
  with many connections (cap arcs to top-N by traffic, note the cap in UI).

### C4. Interactions + navigation

**Design:** Toolbar: **Live / History** segmented control, **Threats only**
toggle, summary chips (countries / active arcs / threats). Right panel: live
destinations list (flag + country/city + connection count + protocol + traffic/
rate; threat rows red). Hover tooltip over a node: app · country · IP · protocol ·
rate · cumulative · role. Add `RootView.Section.map` (SF Symbol `globe`,
`GlobeView` detail). History mode aggregates `ConnectionHistoryRecord` countries.

### 0.1.10 deliverables
As above (localization, lint/tests, docs incl. **Natural Earth attribution in
NOTICE**, version bump, CI release, local verify, review).

---

## File structure (new / modified)

**New (modules / tools / scripts / data):**
- `Sources/MatrixNetMap/{WorldMap,Projection,GlobeGeometry}.swift`
- `Tools/MapConvert/main.swift`, `scripts/build-worldmap.sh`,
  `App/Resources/worldmap.dat`
- App: `SettingsView.swift`, `Preferences.swift`, `LoginItemController.swift`,
  `ActivationPolicy.swift`, `ThreatNotifier.swift`, `MenuBarRateFormatter.swift`,
  `ThroughputHistory.swift`, `OverviewStats.swift`, `GlobeView.swift`,
  `GlobeDestinationsList.swift`, `AppDelegate.swift`

**Modified:**
- `App/Sources/MatrixNetApp.swift` (delegate adaptor, Settings scene, menu-bar
  label, inject app-owned models)
- `App/Sources/AppModel.swift` (throughput history, extended KPIs, notifier hook)
- `App/Sources/OverviewView.swift` (full redesign)
- `App/Sources/MenuBarView.swift` (rate label)
- `App/Sources/RootView.swift` (`.map` section)
- `project.yml` (MatrixNetMap dep, Resources, version bumps),
  `Package.swift` (MatrixNetMap target + tests)
- Localization `.xcstrings`, README / CHANGELOG / NOTICE / DocC

## Testing strategy

Pure logic is the test surface: `Preferences`, `LoginItem` status mapping,
`activationPolicy`, `MenuBarRateFormatter`, `ThreatNotificationPolicy`,
`ThroughputHistory`, `OverviewStats` (KPIs / protocol mix / countries),
`MapConvert` geometry, `EquirectangularProjection`, `GlobeGeometry`
(arc/centroid/radius). Views are assembled from tested units and verified by build
+ manual smoke. CI runs the full Swift Testing suite + lint gates +
`check-localizations.py`.

## Risks / open questions to verify against current docs (no guessing)

- **MenuBarExtra label rate** — confirm the label-based `MenuBarExtra` updates
  live with an `@Observable` model on macOS 26; verify menu-bar text width
  behavior. (Verify in A5.)
- **UNUserNotificationCenter for a Developer-ID (non-sandboxed) app** — confirm
  authorization + delivery works for a notarized non-MAS app and what (if any)
  Info.plist keys/entitlements are needed. (Verify in A6.)
- **SMAppService.mainApp** registration requirements for a Developer-ID app
  installed in /Applications. (Verify in A3.)
- **Natural Earth GeoJSON** exact asset path + field names for ISO-2 / geometry in
  the current `nvkelso/natural-earth-vector` layout. (Verify in C1.)
- **Swift Charts** sector/donut mark API currency on macOS 26. (Verify in B3.)
