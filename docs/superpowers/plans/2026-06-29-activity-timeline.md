# Per-App Activity Timeline Implementation Plan

> REQUIRED SUB-SKILL: superpowers:executing-plans / subagent-driven-development. Checkbox steps.

**Goal:** Visualize the already-persisted hourly usage as a per-app activity timeline (which app was active, when) over a selectable window.

**Architecture:** A pure builder (`ActivityTimelineBuilder`) in `MatrixNetModel` turns `[UsageRow]` + an explicit list of bucket start dates into per-app, bucket-aligned byte series (`ActivityTimeline`). `AppModel.activityTimeline(period:)` reads `usageRows(for:)` and generates the bucket scale from the period's granularity (hourly for Today, daily for 7/30-day). The Usage tab gains a Usage/Timeline segmented mode rendering one heat strip per app. Reuses `UsageStore`/`UsagePeriod`/`UsageBucketing`; no new capture or persistence.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI.

## Global Constraints
- Not capture-only (reads persisted usage). TDD; zero swiftlint/swiftformat warnings; 8-language localization; English public docs/Chinese internal; Apache-2.0; commit identity `Jim Ho <jim.ho@matrixreligio.com>` (no Claude authorship); UI verified via `scripts/smoke.sh`; full regression (tests + built artifact) before review. Version **1.6.0 / 37**; CI canonical; verify appcast `sparkle:version=37`.

## File Structure
- Create `Sources/MatrixNetModel/ActivityTimeline.swift` — `ActivityBucket`, `AppActivityRow`, `ActivityTimeline`, `ActivityTimelineBuilder`.
- Test `Tests/MatrixNetModelTests/ActivityTimelineBuilderTests.swift`.
- Modify `App/Sources/AppModel.swift` — `activityTimeline(period:now:)`.
- Modify `App/Sources/UsageView.swift` (+ a new `ActivityTimelineView`) — Usage/Timeline mode.
- Modify `App/Resources/Localizable.xcstrings`, `CHANGELOG.md`, `README*.md`, `project.yml`.

---

## Task 0: Pure builder (Phase 0 spike)

**Files:** Create `Sources/MatrixNetModel/ActivityTimeline.swift`; Test `Tests/MatrixNetModelTests/ActivityTimelineBuilderTests.swift`.

**Interfaces (produced):**
- `public struct AppActivityRow: Sendable, Equatable { let app: String; let buckets: [UInt64]; let total: UInt64 }`
- `public struct ActivityTimeline: Sendable, Equatable { let hours: [Date]; let rows: [AppActivityRow] }`
- `public enum ActivityTimelineBuilder { static func build(rows: [UsageRow], hours: [Date]) -> ActivityTimeline }`

### Algorithm
- Map each `hours[i]` to index `i`. For each `UsageRow`, find the bucket whose start == the row's `periodStart` snapped to the scale: for hourly scale `periodStart` already equals an hour start, so match directly; the builder matches a row to bucket `i` iff `row.periodStart >= hours[i]` and (`i == hours.count-1` or `row.periodStart < hours[i+1]`). Accumulate `bytesIn + bytesOut` into `series[app][i]`.
- Rows whose `periodStart` is before `hours.first` or ≥ a notional end (after the last bucket's implied span) are ignored — concretely, ignore a row if it is `< hours.first` or `>= hours.last + (hours.last - hours[last-1])` (uniform step); with a single bucket, include `>= hours[0]`.
- Produce `AppActivityRow(app, buckets, total = buckets.reduce(0,+))` for each app; sort rows by `total` descending, then `app` ascending for stable ties. Drop apps whose total is 0.

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("ActivityTimelineBuilder")
struct ActivityTimelineBuilderTests {
    private let h0 = Date(timeIntervalSince1970: 0)
    private var hours: [Date] { (0..<3).map { h0.addingTimeInterval(Double($0) * 3600) } }
    private func row(_ app: String, _ hourIndex: Int, _ bytes: UInt64) -> UsageRow {
        UsageRow(periodStart: h0.addingTimeInterval(Double(hourIndex) * 3600),
                 app: app, host: "h", country: "US", bytesIn: bytes, bytesOut: 0)
    }

    @Test("aligns an app's hourly bytes to the bucket scale, filling gaps with 0")
    func aligns() {
        let timeline = ActivityTimelineBuilder.build(rows: [row("A", 0, 100), row("A", 2, 50)], hours: hours)
        #expect(timeline.rows.count == 1)
        #expect(timeline.rows[0].app == "A")
        #expect(timeline.rows[0].buckets == [100, 0, 50])
        #expect(timeline.rows[0].total == 150)
    }

    @Test("sums in+out and multiple hosts within the same bucket")
    func sums() {
        let rows = [
            UsageRow(periodStart: h0, app: "A", host: "h1", country: "US", bytesIn: 10, bytesOut: 5),
            UsageRow(periodStart: h0, app: "A", host: "h2", country: "US", bytesIn: 20, bytesOut: 0)
        ]
        let timeline = ActivityTimelineBuilder.build(rows: rows, hours: hours)
        #expect(timeline.rows[0].buckets[0] == 35)
    }

    @Test("orders apps by total descending")
    func order() {
        let timeline = ActivityTimelineBuilder.build(rows: [row("Small", 0, 1), row("Big", 0, 999)], hours: hours)
        #expect(timeline.rows.map(\.app) == ["Big", "Small"])
    }

    @Test("ignores rows outside the bucket scale and drops zero-total apps")
    func bounds() {
        let before = row("Old", -5, 100) // before hours.first
        let timeline = ActivityTimelineBuilder.build(rows: [before, row("A", 1, 10)], hours: hours)
        #expect(timeline.rows.map(\.app) == ["A"])
        #expect(timeline.rows[0].buckets == [0, 10, 0])
    }
}
```

- [ ] **Step 2: Run → fail** (`swift test --filter ActivityTimelineBuilder`).

- [ ] **Step 3: Implement `ActivityTimeline.swift`**

```swift
import Foundation

/// One app's network activity over a fixed bucket scale: `buckets[i]` is the
/// total bytes in `ActivityTimeline.hours[i]`. `total` is their sum.
public struct AppActivityRow: Sendable, Equatable {
    public let app: String
    public let buckets: [UInt64]
    public let total: UInt64

    public init(app: String, buckets: [UInt64], total: UInt64) {
        self.app = app
        self.buckets = buckets
        self.total = total
    }
}

/// A per-app activity timeline aligned to a shared list of bucket start dates.
public struct ActivityTimeline: Sendable, Equatable {
    public let hours: [Date]
    public let rows: [AppActivityRow]

    public init(hours: [Date], rows: [AppActivityRow]) {
        self.hours = hours
        self.rows = rows
    }
}

/// Builds an `ActivityTimeline` from hourly usage rows and an explicit bucket
/// scale. Pure: the caller supplies `hours` (the bucket start dates, ascending),
/// so the same builder serves hourly (Today) and daily (multi-day) windows.
public enum ActivityTimelineBuilder {
    public static func build(rows: [UsageRow], hours: [Date]) -> ActivityTimeline {
        guard !hours.isEmpty else { return ActivityTimeline(hours: hours, rows: []) }
        let step = hours.count > 1 ? hours[1].timeIntervalSince(hours[0]) : 3600
        let end = hours[hours.count - 1].addingTimeInterval(step)

        var series: [String: [UInt64]] = [:]
        for row in rows {
            let t = row.periodStart
            guard t >= hours[0], t < end else { continue }
            // Uniform step → integer bucket index.
            let index = min(hours.count - 1, Int(t.timeIntervalSince(hours[0]) / step))
            var buckets = series[row.app] ?? [UInt64](repeating: 0, count: hours.count)
            buckets[index] &+= row.bytesIn &+ row.bytesOut
            series[row.app] = buckets
        }

        let appRows = series.map { app, buckets in
            AppActivityRow(app: app, buckets: buckets, total: buckets.reduce(0, &+))
        }
        .filter { $0.total > 0 }
        .sorted { $0.total != $1.total ? $0.total > $1.total : $0.app < $1.app }

        return ActivityTimeline(hours: hours, rows: appRows)
    }
}
```

- [ ] **Step 4: Run → pass.** **Step 5: Lint.** **Step 6: Commit** `feat(model): ActivityTimelineBuilder — per-app hourly activity series`.
- [ ] **Step 7: SPIKE GATE** — code-reviewer (bucket-index rounding, non-uniform step safety, overflow, ordering). Fix before Task 1.

---

## Task 1: AppModel + Usage/Timeline UI + localization

- [ ] **Step 1:** `AppModel.activityTimeline(period:now:)`:
```swift
public func activityTimeline(period: UsagePeriod, now: Date = Date()) -> ActivityTimeline {
    let calendar = Calendar.current
    let (start, end) = period.range(now: now, calendar: calendar)
    let rows = usageRows(for: period)
    let step: TimeInterval = period.trendGranularity == .hour ? 3600 : 86_400
    let anchor = period.trendGranularity == .hour
        ? UsageBucketing.hourStart(of: start, calendar: calendar)
        : calendar.startOfDay(for: start)
    var hours: [Date] = []
    var t = anchor
    while t < end { hours.append(t); t = t.addingTimeInterval(step) }
    // For daily buckets, snap each row's hourly periodStart to its day so it lands
    // in the right daily bucket (builder uses uniform step from the anchor).
    return ActivityTimelineBuilder.build(rows: rows, hours: hours)
}
```
(Daily rows: `UsageRow.periodStart` is an hour; the builder's `Int(elapsed/step)` with step=86400 maps any hour within a day to that day's index — correct.)

- [ ] **Step 2:** `ActivityTimelineView` (new): given an `ActivityTimeline`, render Top-N app rows, each a horizontal strip of cells coloured by `log`-scaled bytes vs the timeline max; app icon+name on the left; `.help` per cell with the bucket time + `Format.bytes`. Empty state when `rows.isEmpty`.

- [ ] **Step 3:** In `UsageView`, add a segmented control (Usage / Timeline) reusing the existing period picker; show `ActivityTimelineView(timeline: model.activityTimeline(period:))` in Timeline mode.

- [ ] **Step 4:** Localize new strings ×8: "Timeline", "Activity", "No activity yet — usage will appear here as your apps use the network." (+ any cell/section labels). Preserve xcstrings key order (append).

- [ ] **Step 5:** Build + full `swift test`. **Step 6:** Lint (`swiftformat Sources App --lint && swiftlint --strict`). **Step 7:** `scripts/smoke.sh` signed launch + screenshot of the Timeline mode (temporarily default the Usage mode to Timeline if needed to verify, then revert). **Step 8:** Commit.

---

## Task 2: Docs + version 1.6.0/37 + release
- [ ] CHANGELOG `## [1.6.0]` Added: per-app activity timeline; **Fixed**: Packets empty states now centered (the already-committed UI fix rides here).
- [ ] README ×8 bullet ("Per-app activity timeline — see when each app was active, by hour/day, from persisted usage").
- [ ] project.yml → 1.6.0 / 37 (settings.base + both info.properties).
- [ ] Full regression (tests + smoke + dataset check). Commit `release: per-app activity timeline (1.6.0)` + tag v1.6.0 + push + `gh workflow run release.yml -f version=v1.6.0`.
- [ ] Verify CI success, appcast `sparkle:version=37`, DMG datasets, local launch.

## Self-Review
- Coverage: hourly series + alignment/gaps (Task 0); daily window via uniform step; per-app order; UI mode + empty state (Task 1); 1.6.0/37 + 8-lang docs (Task 2). Names: `ActivityTimeline`/`AppActivityRow`/`ActivityTimelineBuilder.build`/`activityTimeline(period:)`. No placeholders.
