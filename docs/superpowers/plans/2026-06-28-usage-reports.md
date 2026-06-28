# Per-App Usage Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Usage" tab that answers "where did my bandwidth go" — Top apps / countries / domains by byte usage over Today / 7 days / 30 days / current billing cycle.

**Architecture:** PKTAP packets accumulate monotonic per-(app, address) byte totals in `ConnectionAggregator` (surviving connection close). `AppModel` polls that snapshot every ≥30s, diffs against the last snapshot, resolves country (GeoIP) + hostname, buckets the deltas by hour, and additively upserts them into a SwiftData `UsageStore`. Closed hours are compacted to Top-N domains. A new `UsageView` reads a time range and aggregates the hourly buckets with pure `UsageReport` functions.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftData, SwiftUI + Swift Charts, XcodeGen.

## Global Constraints

- Swift 6 strict concurrency; zero warnings. SwiftLint `--strict` + SwiftFormat must pass.
- TDD: no production code without a failing test first (UI views excepted — their logic lives in tested pure types).
- Open-source code/comments/DocC = English; spec/plan = Chinese. Commits carry NO Claude authorship / no "Generated with Claude".
- Localize every new UI string into 8 languages (en base + de, es, fr, ja, ko, zh-Hans, zh-Hant); `scripts/check-localizations.py` must pass.
- Zero conflict with proxy/filter software: passive only, no NetworkExtension.
- SwiftData cannot store `UInt64` → persist bytes as `Int`; pure types use `UInt64`.
- Aggregation granularity: hourly buckets; default retention 90 days (`usageRetentionDays`); Top-N domains per (hour, app) with N=20, tail folded into synthetic host `·other` / country `—`.
- Version source of truth: project.yml (6 places) + run `xcodegen generate`.

---

## File Structure

**MatrixNetModel (pure logic, new):**
- `Sources/MatrixNetModel/UsageTotals.swift` — `UsageTotals` value type + `+`.
- `Sources/MatrixNetModel/UsageRow.swift` — `UsageRow` value type (one hourly bucket).
- `Sources/MatrixNetModel/UsageAccumulator.swift` — pure cumulative→delta diffing.
- `Sources/MatrixNetModel/UsageBucketing.swift` — hour flooring.
- `Sources/MatrixNetModel/UsageTruncation.swift` — Top-N domain truncation.
- `Sources/MatrixNetModel/UsagePeriod.swift` — period presets + billing-cycle range math.
- `Sources/MatrixNetModel/UsageReport.swift` — aggregations (byApp/byCountry/byDomain/trend/totals).

**MatrixNetStore (persistence, new):**
- `Sources/MatrixNetStore/UsageBucketRecord.swift` — `@Model`.
- `Sources/MatrixNetStore/UsageStore.swift` — `@MainActor` store.

**MatrixNetCapture (modify):**
- `Sources/MatrixNetCapture/ConnectionAggregator.swift` — add `UsageFlowTotal`, `usageByFlow`, `usageSnapshot()`.

**App (modify / new):**
- `App/Sources/AppModel.swift` — orchestrate flush/compact/prune; expose `usageRows(for:)`.
- `App/Sources/RootView.swift` — add `.usage` section.
- `App/Sources/UsageView.swift` + `App/Sources/UsagePanels.swift` — UI (new).
- `Sources/MatrixNetModel/Preferences.swift` — add `usageRetentionDays`, `billingCycleResetDay`.
- `App/Sources/SettingsView.swift` — two new steppers.
- `App/Resources/Localizable.xcstrings` — new strings ×8 langs.

**Tests (new):**
- `Tests/MatrixNetModelTests/UsageAccumulatorTests.swift`, `UsageBucketingTests.swift`, `UsageTruncationTests.swift`, `UsagePeriodTests.swift`, `UsageReportTests.swift`.
- `Tests/MatrixNetStoreTests/UsageStoreTests.swift`.
- `Tests/MatrixNetCaptureTests/ConnectionAggregatorUsageTests.swift`.

---

## Task 1: Pure value types + delta accumulator + hour bucketing

**Files:**
- Create: `Sources/MatrixNetModel/UsageTotals.swift`, `Sources/MatrixNetModel/UsageRow.swift`, `Sources/MatrixNetModel/UsageAccumulator.swift`, `Sources/MatrixNetModel/UsageBucketing.swift`
- Test: `Tests/MatrixNetModelTests/UsageAccumulatorTests.swift`, `Tests/MatrixNetModelTests/UsageBucketingTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageTotals: Sendable, Equatable { var bytesIn: UInt64; var bytesOut: UInt64; static func + }`
  - `struct UsageRow: Sendable, Equatable { let periodStart: Date; let app: String; let host: String; let country: String; var bytesIn: UInt64; var bytesOut: UInt64 }`
  - `enum UsageAccumulator { static func deltas(previous: [String: UsageTotals], current: [String: UsageTotals]) -> [String: UsageTotals] }`
  - `enum UsageBucketing { static func hourStart(of: Date, calendar: Calendar) -> Date }`

- [ ] **Step 1: Write the failing tests**

`Tests/MatrixNetModelTests/UsageBucketingTests.swift`:
```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageBucketing")
struct UsageBucketingTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c
    }

    @Test("floors a timestamp to the start of its hour")
    func floorsToHour() {
        // 1970-01-01 03:47:23 UTC → 03:00:00 UTC.
        let date = Date(timeIntervalSince1970: TimeInterval(3 * 3600 + 47 * 60 + 23))
        #expect(UsageBucketing.hourStart(of: date, calendar: utc) == Date(timeIntervalSince1970: 3 * 3600))
    }

    @Test("an exact hour is unchanged")
    func exactHour() {
        let date = Date(timeIntervalSince1970: 5 * 3600)
        #expect(UsageBucketing.hourStart(of: date, calendar: utc) == date)
    }
}
```

`Tests/MatrixNetModelTests/UsageAccumulatorTests.swift`:
```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageAccumulator")
struct UsageAccumulatorTests {
    private func t(_ i: UInt64, _ o: UInt64) -> UsageTotals { UsageTotals(bytesIn: i, bytesOut: o) }

    @Test("a brand-new key counts its full current total")
    func newKey() {
        let d = UsageAccumulator.deltas(previous: [:], current: ["a": t(100, 20)])
        #expect(d == ["a": t(100, 20)])
    }

    @Test("an advancing key counts only the positive growth")
    func growth() {
        let d = UsageAccumulator.deltas(previous: ["a": t(100, 20)], current: ["a": t(150, 25)])
        #expect(d == ["a": t(50, 5)])
    }

    @Test("a reset counter clamps to zero, never negative")
    func reset() {
        let d = UsageAccumulator.deltas(previous: ["a": t(100, 20)], current: ["a": t(10, 5)])
        #expect(d.isEmpty) // both deltas clamp to 0 → omitted
    }

    @Test("unchanged keys produce no delta")
    func unchanged() {
        let d = UsageAccumulator.deltas(previous: ["a": t(100, 20)], current: ["a": t(100, 20)])
        #expect(d.isEmpty)
    }

    @Test("mixed growth: one direction grows, the other resets")
    func mixed() {
        let d = UsageAccumulator.deltas(previous: ["a": t(100, 20)], current: ["a": t(120, 5)])
        #expect(d == ["a": t(20, 0)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "UsageBucketing|UsageAccumulator"`
Expected: FAIL — `cannot find 'UsageBucketing'` / `'UsageAccumulator'` in scope.

- [ ] **Step 3: Write minimal implementations**

`Sources/MatrixNetModel/UsageTotals.swift`:
```swift
import Foundation

/// Inbound/outbound byte counters for one app, destination, or bucket.
public struct UsageTotals: Sendable, Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(bytesIn: lhs.bytesIn + rhs.bytesIn, bytesOut: lhs.bytesOut + rhs.bytesOut)
    }
}
```

`Sources/MatrixNetModel/UsageRow.swift`:
```swift
import Foundation

/// One hourly usage bucket: bytes for an (app, host, country) within the hour
/// starting at `periodStart`.
public struct UsageRow: Sendable, Equatable {
    public let periodStart: Date
    public let app: String
    public let host: String
    public let country: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(periodStart: Date, app: String, host: String, country: String,
                bytesIn: UInt64, bytesOut: UInt64) {
        self.periodStart = periodStart
        self.app = app
        self.host = host
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
```

`Sources/MatrixNetModel/UsageBucketing.swift`:
```swift
import Foundation

/// Maps timestamps to the start of their hour bucket.
public enum UsageBucketing {
    /// The start of the hour containing `date`, in `calendar`'s time zone.
    public static func hourStart(of date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: parts) ?? date
    }
}
```

`Sources/MatrixNetModel/UsageAccumulator.swift`:
```swift
import Foundation

/// Turns successive cumulative (monotonic) snapshots into per-key positive
/// deltas. A reset or new key is handled by clamping each direction to ≥ 0;
/// keys whose two deltas are both zero are omitted.
public enum UsageAccumulator {
    public static func deltas(previous: [String: UsageTotals],
                              current: [String: UsageTotals]) -> [String: UsageTotals] {
        var result: [String: UsageTotals] = [:]
        for (key, now) in current {
            let was = previous[key] ?? UsageTotals()
            let dIn = now.bytesIn >= was.bytesIn ? now.bytesIn - was.bytesIn : now.bytesIn
            let dOut = now.bytesOut >= was.bytesOut ? now.bytesOut - was.bytesOut : now.bytesOut
            if dIn > 0 || dOut > 0 {
                result[key] = UsageTotals(bytesIn: dIn, bytesOut: dOut)
            }
        }
        return result
    }
}
```

> Note on `reset()` semantics: when `now < was` we count `now` as the delta (a fresh counter starting from 0 grew to `now`). The "reset" test uses `now=10 < was=100` so `dIn=10`, `dOut=5` — both > 0 → NOT omitted. **Fix the test to match:** the reset test must expect `["a": t(10, 5)]`, not empty. Update Step 1's `reset()` test accordingly before running.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "UsageBucketing|UsageAccumulator"`
Expected: PASS (after the reset-test correction above).

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/UsageTotals.swift Sources/MatrixNetModel/UsageRow.swift \
  Sources/MatrixNetModel/UsageBucketing.swift Sources/MatrixNetModel/UsageAccumulator.swift \
  Tests/MatrixNetModelTests/UsageBucketingTests.swift Tests/MatrixNetModelTests/UsageAccumulatorTests.swift
git commit -m "Add usage value types, hour bucketing, and delta accumulator"
```

---

## Task 2: Top-N domain truncation

**Files:**
- Create: `Sources/MatrixNetModel/UsageTruncation.swift`
- Test: `Tests/MatrixNetModelTests/UsageTruncationTests.swift`

**Interfaces:**
- Consumes: `UsageRow` (Task 1).
- Produces: `enum UsageTruncation { static let otherHost = "·other"; static let mixedCountry = "—"; static func topN(_ rows: [UsageRow], n: Int) -> [UsageRow] }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageTruncation")
struct UsageTruncationTests {
    private let hour = Date(timeIntervalSince1970: 0)
    private func row(_ app: String, _ host: String, _ bytes: UInt64) -> UsageRow {
        UsageRow(periodStart: hour, app: app, host: host, country: "US", bytesIn: bytes, bytesOut: 0)
    }

    @Test("groups with at most n hosts are returned unchanged")
    func underLimit() {
        let rows = [row("A", "x.com", 10), row("A", "y.com", 5)]
        let out = UsageTruncation.topN(rows, n: 5)
        #expect(out.count == 2)
    }

    @Test("the long tail past the top n folds into one ·other row")
    func foldsTail() {
        let rows = [row("A", "a", 100), row("A", "b", 50), row("A", "c", 9), row("A", "d", 1)]
        let out = UsageTruncation.topN(rows, n: 2)
        #expect(out.count == 3) // a, b, ·other
        let other = out.first { $0.host == UsageTruncation.otherHost }
        #expect(other?.bytesIn == 10) // 9 + 1
        #expect(other?.country == UsageTruncation.mixedCountry)
    }

    @Test("each app is truncated independently")
    func perApp() {
        let rows = [row("A", "a", 5), row("A", "b", 4), row("A", "c", 3),
                    row("B", "z", 1)]
        let out = UsageTruncation.topN(rows, n: 2)
        #expect(out.filter { $0.app == "A" }.count == 3) // a, b, ·other
        #expect(out.filter { $0.app == "B" }.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageTruncation`
Expected: FAIL — `cannot find 'UsageTruncation' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Bounds storage by keeping only the top-N destinations per (hour, app) and
/// folding the long tail into a single synthetic "other" row.
public enum UsageTruncation {
    public static let otherHost = "·other"
    public static let mixedCountry = "—"

    public static func topN(_ rows: [UsageRow], n: Int) -> [UsageRow] {
        var byApp: [String: [UsageRow]] = [:]
        var order: [String] = []
        for row in rows {
            if byApp[row.app] == nil { order.append(row.app) }
            byApp[row.app, default: []].append(row)
        }
        var result: [UsageRow] = []
        for app in order {
            let group = byApp[app] ?? []
            guard group.count > n else { result.append(contentsOf: group); continue }
            let sorted = group.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            result.append(contentsOf: sorted.prefix(n))
            let tail = sorted.dropFirst(n)
            let inSum = tail.reduce(UInt64(0)) { $0 + $1.bytesIn }
            let outSum = tail.reduce(UInt64(0)) { $0 + $1.bytesOut }
            result.append(UsageRow(periodStart: group[0].periodStart, app: app,
                                   host: otherHost, country: mixedCountry,
                                   bytesIn: inSum, bytesOut: outSum))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageTruncation`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/UsageTruncation.swift Tests/MatrixNetModelTests/UsageTruncationTests.swift
git commit -m "Add top-N domain truncation for usage buckets"
```

---

## Task 3: Period presets + billing-cycle range math

**Files:**
- Create: `Sources/MatrixNetModel/UsagePeriod.swift`
- Test: `Tests/MatrixNetModelTests/UsagePeriodTests.swift`

**Interfaces:**
- Produces:
  - `enum TrendGranularity: Sendable { case hour, day }`
  - `enum UsagePeriod: Sendable, Equatable { case today, last7Days, last30Days, currentCycle(resetDay: Int); func range(now: Date, calendar: Calendar) -> (start: Date, end: Date); var trendGranularity: TrendGranularity }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsagePeriod")
struct UsagePeriodTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }
    // 2026-06-15 10:30:00 UTC
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10, minute: 30))! }

    @Test("today starts at local midnight and ends at now")
    func today() {
        let r = UsagePeriod.today.range(now: now, calendar: cal)
        #expect(r.start == cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!)
        #expect(r.end == now)
    }

    @Test("last 7 days spans 7 days back to now")
    func last7() {
        let r = UsagePeriod.last7Days.range(now: now, calendar: cal)
        #expect(r.start == cal.date(byAdding: .day, value: -7, to: now)!)
        #expect(r.end == now)
    }

    @Test("a cycle reset day earlier this month starts on that day")
    func cycleThisMonth() {
        let r = UsagePeriod.currentCycle(resetDay: 5).range(now: now, calendar: cal)
        #expect(r.start == cal.date(from: DateComponents(year: 2026, month: 6, day: 5))!)
    }

    @Test("a cycle reset day later than today rolls back to last month")
    func cyclePrevMonth() {
        let r = UsagePeriod.currentCycle(resetDay: 20).range(now: now, calendar: cal)
        #expect(r.start == cal.date(from: DateComponents(year: 2026, month: 5, day: 20))!)
    }

    @Test("a reset day past the month length clamps to the last valid day")
    func cycleClamp() {
        // now = Feb 15 2026; resetDay 31 → Feb has 28 days in 2026 → Feb 28.
        let feb = cal.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 9))!
        let r = UsagePeriod.currentCycle(resetDay: 31).range(now: feb, calendar: cal)
        #expect(r.start == cal.date(from: DateComponents(year: 2026, month: 1, day: 31))!)
    }

    @Test("trend granularity is hourly for today, daily otherwise")
    func granularity() {
        #expect(UsagePeriod.today.trendGranularity == .hour)
        #expect(UsagePeriod.last30Days.trendGranularity == .day)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsagePeriod`
Expected: FAIL — `cannot find 'UsagePeriod' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum TrendGranularity: Sendable, Equatable { case hour, day }

/// A selectable reporting window for the Usage tab.
public enum UsagePeriod: Sendable, Equatable {
    case today
    case last7Days
    case last30Days
    case currentCycle(resetDay: Int)

    public var trendGranularity: TrendGranularity {
        switch self {
        case .today: .hour
        default: .day
        }
    }

    public func range(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: now) ?? now, now)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now) ?? now, now)
        case let .currentCycle(resetDay):
            return (Self.cycleStart(resetDay: resetDay, now: now, calendar: calendar), now)
        }
    }

    /// The most recent billing-cycle anchor ≤ now: the reset day this month if it
    /// has already passed, else last month; clamped to each month's length.
    private static func cycleStart(resetDay: Int, now: Date, calendar: Calendar) -> Date {
        let clampedDay = max(1, min(28, resetDay)) == resetDay ? resetDay : resetDay
        func anchor(year: Int, month: Int) -> Date {
            var comps = DateComponents(year: year, month: month, day: 1)
            let monthDate = calendar.date(from: comps) ?? now
            let length = calendar.range(of: .day, in: .month, for: monthDate)?.count ?? 28
            comps.day = min(clampedDay, length)
            return calendar.date(from: comps) ?? now
        }
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 2000
        let month = parts.month ?? 1
        let thisMonth = anchor(year: year, month: month)
        if thisMonth <= now { return thisMonth }
        let prev = month == 1 ? (year - 1, 12) : (year, month - 1)
        return anchor(year: prev.0, month: prev.1)
    }
}
```

> The `clampedDay` line above intentionally preserves `resetDay` and lets the per-month `min(clampedDay, length)` do the clamping, so `resetDay: 31` becomes Jan 31 (length 31) but Feb 28. Replace the redundant first line with `let clampedDay = max(1, resetDay)` for clarity.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsagePeriod`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/UsagePeriod.swift Tests/MatrixNetModelTests/UsagePeriodTests.swift
git commit -m "Add usage period presets and billing-cycle range math"
```

---

## Task 4: Report aggregations

**Files:**
- Create: `Sources/MatrixNetModel/UsageReport.swift`
- Test: `Tests/MatrixNetModelTests/UsageReportTests.swift`

**Interfaces:**
- Consumes: `UsageRow`, `UsageTotals`, `TrendGranularity`, `UsageBucketing`, `UsageTruncation`.
- Produces:
  - `struct AppUsage: Sendable, Equatable { let app: String; let totals: UsageTotals }`
  - `struct CountryUsage: Sendable, Equatable { let country: String; let totals: UsageTotals }`
  - `struct DomainUsage: Sendable, Equatable { let host: String; let totals: UsageTotals }`
  - `struct TrendBucket: Sendable, Equatable { let start: Date; let totals: UsageTotals }`
  - `enum UsageReport { static func totals(_:); static func byApp(_:); static func byCountry(_:); static func byDomain(_:app:); static func trend(_:by:calendar:) }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageReport")
struct UsageReportTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }
    private func row(_ app: String, _ host: String, _ country: String, _ hour: Int, _ b: UInt64) -> UsageRow {
        UsageRow(periodStart: Date(timeIntervalSince1970: TimeInterval(hour * 3600)),
                 app: app, host: host, country: country, bytesIn: b, bytesOut: 0)
    }
    private var rows: [UsageRow] {
        [row("A", "x", "US", 0, 100), row("A", "y", "DE", 0, 50),
         row("B", "z", "US", 1, 30), row("A", "x", "US", 1, 10)]
    }

    @Test("totals sum every row")
    func totals() {
        #expect(UsageReport.totals(rows) == UsageTotals(bytesIn: 190, bytesOut: 0))
    }

    @Test("byApp groups and sorts descending")
    func byApp() {
        let r = UsageReport.byApp(rows)
        #expect(r.map(\.app) == ["A", "B"])
        #expect(r[0].totals.bytesIn == 160)
    }

    @Test("byCountry groups across apps")
    func byCountry() {
        let r = UsageReport.byCountry(rows)
        #expect(r.first { $0.country == "US" }?.totals.bytesIn == 140)
        #expect(r.first { $0.country == "DE" }?.totals.bytesIn == 50)
    }

    @Test("byDomain can filter to one app")
    func byDomain() {
        let r = UsageReport.byDomain(rows, app: "A")
        #expect(r.first { $0.host == "x" }?.totals.bytesIn == 110)
        #expect(r.contains { $0.host == "z" } == false)
    }

    @Test("hourly trend keeps each hour separate")
    func trendHour() {
        let r = UsageReport.trend(rows, by: .hour, calendar: cal)
        #expect(r.count == 2)
        #expect(r[0].totals.bytesIn == 150)
        #expect(r[1].totals.bytesIn == 40)
    }

    @Test("daily trend collapses hours into one day")
    func trendDay() {
        let r = UsageReport.trend(rows, by: .day, calendar: cal)
        #expect(r.count == 1)
        #expect(r[0].totals.bytesIn == 190)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageReport`
Expected: FAIL — `cannot find 'UsageReport' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct AppUsage: Sendable, Equatable { public let app: String; public let totals: UsageTotals }
public struct CountryUsage: Sendable, Equatable { public let country: String; public let totals: UsageTotals }
public struct DomainUsage: Sendable, Equatable { public let host: String; public let totals: UsageTotals }
public struct TrendBucket: Sendable, Equatable { public let start: Date; public let totals: UsageTotals }

/// Pure aggregations over a fetched set of hourly usage rows.
public enum UsageReport {
    public static func totals(_ rows: [UsageRow]) -> UsageTotals {
        rows.reduce(UsageTotals()) { $0 + UsageTotals(bytesIn: $1.bytesIn, bytesOut: $1.bytesOut) }
    }

    public static func byApp(_ rows: [UsageRow]) -> [AppUsage] {
        group(rows, key: \.app).map { AppUsage(app: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func byCountry(_ rows: [UsageRow]) -> [CountryUsage] {
        group(rows, key: \.country).map { CountryUsage(country: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func byDomain(_ rows: [UsageRow], app: String?) -> [DomainUsage] {
        let filtered = app.map { a in rows.filter { $0.app == a } } ?? rows
        return group(filtered, key: \.host).map { DomainUsage(host: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func trend(_ rows: [UsageRow], by granularity: TrendGranularity,
                             calendar: Calendar) -> [TrendBucket] {
        var buckets: [Date: UsageTotals] = [:]
        for row in rows {
            let key = granularity == .hour
                ? UsageBucketing.hourStart(of: row.periodStart, calendar: calendar)
                : calendar.startOfDay(for: row.periodStart)
            buckets[key, default: UsageTotals()] = buckets[key, default: UsageTotals()]
                + UsageTotals(bytesIn: row.bytesIn, bytesOut: row.bytesOut)
        }
        return buckets.map { TrendBucket(start: $0.key, totals: $0.value) }
            .sorted { $0.start < $1.start }
    }

    private static func total(_ t: UsageTotals) -> UInt64 { t.bytesIn + t.bytesOut }

    private static func group(_ rows: [UsageRow], key: (UsageRow) -> String) -> [String: UsageTotals] {
        var out: [String: UsageTotals] = [:]
        for row in rows {
            out[key(row), default: UsageTotals()] = out[key(row), default: UsageTotals()]
                + UsageTotals(bytesIn: row.bytesIn, bytesOut: row.bytesOut)
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageReport`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/UsageReport.swift Tests/MatrixNetModelTests/UsageReportTests.swift
git commit -m "Add usage report aggregations (app/country/domain/trend)"
```

---

## Task 5: SwiftData usage store

**Files:**
- Create: `Sources/MatrixNetStore/UsageBucketRecord.swift`, `Sources/MatrixNetStore/UsageStore.swift`
- Test: `Tests/MatrixNetStoreTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageRow`, `UsageTruncation` (MatrixNetModel).
- Produces:
  - `@Model final class UsageBucketRecord { var periodStart: Date; var app: String; var host: String; var country: String; var bytesIn: Int; var bytesOut: Int }`
  - `@MainActor final class UsageStore { init(container:); static func inMemory() throws; static func persistent() throws; func accumulate(_ rows: [UsageRow]) throws; func compactHour(_ hourStart: Date, n: Int) throws; func fetch(range:) throws -> [UsageRow]; func prune(olderThan: Date) throws; func distinctHours(before: Date) throws -> [Date] }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MatrixNetModel
@testable import MatrixNetStore

@MainActor
@Suite("UsageStore")
struct UsageStoreTests {
    private let hour = Date(timeIntervalSince1970: 0)
    private func row(_ app: String, _ host: String, _ b: UInt64, at: Date) -> UsageRow {
        UsageRow(periodStart: at, app: app, host: host, country: "US", bytesIn: b, bytesOut: 0)
    }

    @Test("accumulate adds bytes for the same key")
    func additiveUpsert() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([row("A", "x", 10, at: hour)])
        try store.accumulate([row("A", "x", 5, at: hour)])
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 1)
        #expect(out[0].bytesIn == 15)
    }

    @Test("fetch range is half-open [start, end)")
    func fetchRange() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([row("A", "x", 10, at: hour),
                              row("A", "y", 7, at: hour.addingTimeInterval(7200))])
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 1)
    }

    @Test("compactHour folds the tail beyond n into ·other")
    func compact() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([row("A", "a", 100, at: hour), row("A", "b", 50, at: hour),
                              row("A", "c", 9, at: hour), row("A", "d", 1, at: hour)])
        try store.compactHour(hour, n: 2)
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 3)
        #expect(out.contains { $0.host == UsageTruncation.otherHost && $0.bytesIn == 10 })
    }

    @Test("compactHour is idempotent")
    func compactIdempotent() throws {
        let store = try UsageStore.inMemory()
        try store.accumulate([row("A", "a", 100, at: hour), row("A", "b", 50, at: hour),
                              row("A", "c", 9, at: hour), row("A", "d", 1, at: hour)])
        try store.compactHour(hour, n: 2)
        try store.compactHour(hour, n: 2)
        let out = try store.fetch(range: (hour, hour.addingTimeInterval(3600)))
        #expect(out.count == 3)
    }

    @Test("prune deletes rows older than the cutoff")
    func prune() throws {
        let store = try UsageStore.inMemory()
        let old = Date(timeIntervalSince1970: 0)
        let recent = Date(timeIntervalSince1970: 100_000)
        try store.accumulate([row("A", "x", 1, at: old), row("A", "y", 1, at: recent)])
        try store.prune(olderThan: Date(timeIntervalSince1970: 50_000))
        let out = try store.fetch(range: (Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 200_000)))
        #expect(out.count == 1)
        #expect(out[0].host == "y")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageStore`
Expected: FAIL — `cannot find 'UsageStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/MatrixNetStore/UsageBucketRecord.swift`:
```swift
import Foundation
import SwiftData

/// One persisted hourly usage bucket. Bytes are `Int` because SwiftData cannot
/// store `UInt64`; traffic volumes stay well within `Int.max`.
@Model
public final class UsageBucketRecord {
    public var periodStart: Date
    public var app: String
    public var host: String
    public var country: String
    public var bytesIn: Int
    public var bytesOut: Int

    public init(periodStart: Date, app: String, host: String, country: String,
                bytesIn: Int, bytesOut: Int) {
        self.periodStart = periodStart
        self.app = app
        self.host = host
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
```

`Sources/MatrixNetStore/UsageStore.swift`:
```swift
import Foundation
import MatrixNetModel
import SwiftData

/// Persists hourly usage buckets with SwiftData, upserting additively by
/// (hour, app, host, country) so a crash mid-hour loses at most one flush.
@MainActor
public final class UsageStore {
    private let container: ModelContainer

    public init(container: ModelContainer) { self.container = container }

    public static func inMemory() throws -> UsageStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return UsageStore(container: try ModelContainer(for: UsageBucketRecord.self, configurations: config))
    }

    public static func persistent() throws -> UsageStore {
        UsageStore(container: try ModelContainer(for: UsageBucketRecord.self))
    }

    public func accumulate(_ rows: [UsageRow]) throws {
        let context = container.mainContext
        for row in rows {
            let start = row.periodStart, app = row.app, host = row.host, country = row.country
            var descriptor = FetchDescriptor<UsageBucketRecord>(
                predicate: #Predicate { $0.periodStart == start && $0.app == app
                    && $0.host == host && $0.country == country })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                existing.bytesIn += clampInt(row.bytesIn)
                existing.bytesOut += clampInt(row.bytesOut)
            } else {
                context.insert(UsageBucketRecord(periodStart: start, app: app, host: host,
                    country: country, bytesIn: clampInt(row.bytesIn), bytesOut: clampInt(row.bytesOut)))
            }
        }
        try context.save()
    }

    public func compactHour(_ hourStart: Date, n: Int) throws {
        let context = container.mainContext
        let end = hourStart.addingTimeInterval(3600)
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart >= hourStart && $0.periodStart < end })
        let records = try context.fetch(descriptor)
        let rows = records.map(Self.toRow)
        let truncated = UsageTruncation.topN(rows, n: n)
        guard truncated.count != records.count else { return } // already compact → no-op
        for record in records { context.delete(record) }
        for row in truncated {
            context.insert(UsageBucketRecord(periodStart: row.periodStart, app: row.app,
                host: row.host, country: row.country,
                bytesIn: clampInt(row.bytesIn), bytesOut: clampInt(row.bytesOut)))
        }
        try context.save()
    }

    public func fetch(range: (start: Date, end: Date)) throws -> [UsageRow] {
        let start = range.start, end = range.end
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart >= start && $0.periodStart < end })
        return try container.mainContext.fetch(descriptor).map(Self.toRow)
    }

    public func prune(olderThan cutoff: Date) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart < cutoff })
        for record in try context.fetch(descriptor) { context.delete(record) }
        try context.save()
    }

    public func distinctHours(before: Date) throws -> [Date] {
        let descriptor = FetchDescriptor<UsageBucketRecord>(
            predicate: #Predicate { $0.periodStart < before })
        return Array(Set(try container.mainContext.fetch(descriptor).map(\.periodStart))).sorted()
    }

    private static func toRow(_ r: UsageBucketRecord) -> UsageRow {
        UsageRow(periodStart: r.periodStart, app: r.app, host: r.host, country: r.country,
                 bytesIn: UInt64(max(0, r.bytesIn)), bytesOut: UInt64(max(0, r.bytesOut)))
    }
}

private func clampInt(_ value: UInt64) -> Int { Int(min(value, UInt64(Int.max))) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageStore`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetStore/UsageBucketRecord.swift Sources/MatrixNetStore/UsageStore.swift \
  Tests/MatrixNetStoreTests/UsageStoreTests.swift
git commit -m "Add SwiftData usage store with additive upsert, compaction, prune"
```

---

## Task 6: Aggregator monotonic per-flow usage snapshot

**Files:**
- Modify: `Sources/MatrixNetCapture/ConnectionAggregator.swift`
- Test: `Tests/MatrixNetCaptureTests/ConnectionAggregatorUsageTests.swift`

**Interfaces:**
- Consumes: existing `ConnectionAggregator`, `Connection`, `IPAddress`.
- Produces: `struct ConnectionAggregator.UsageFlowTotal: Sendable { let app: String; let address: IPAddress; var bytesIn: UInt64; var bytesOut: UInt64 }` and `func usageSnapshot() -> [UsageFlowTotal]`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MatrixNetCapture
@testable import MatrixNetModel

@Suite("ConnectionAggregator usage snapshot")
struct ConnectionAggregatorUsageTests {
    private func connection(_ app: String, _ ip: String, _ port: UInt16) -> Connection {
        let dst = Endpoint(address: IPAddress(ip)!, port: port)
        let src = Endpoint(address: IPAddress("10.0.0.2")!, port: 5555)
        let tuple = FiveTuple(proto: .tcp, source: src, destination: dst)
        return Connection(fiveTuple: tuple, app: AppIdentity(pid: 1, executablePath: "/A/\(app)"))
    }

    @Test("packet bytes accumulate per app+address and survive connection close")
    func survivesClose() async {
        let agg = ConnectionAggregator()
        let conn = connection("Mail", "1.1.1.1", 443)
        await agg.apply(.added(connection: conn))
        await agg.attributePackets([
            .init(flowKey: conn.fiveTuple.packetFlowKey, pid: 1, inbound: true, bytes: 500),
            .init(flowKey: conn.fiveTuple.packetFlowKey, pid: 1, inbound: false, bytes: 100),
        ])
        await agg.apply(.removed(id: conn.id))
        let snap = await agg.usageSnapshot()
        #expect(snap.count == 1)
        #expect(snap[0].bytesIn == 500)
        #expect(snap[0].bytesOut == 100)
        #expect(snap[0].address.description == "1.1.1.1")
    }

    @Test("reset clears usage")
    func resetClears() async {
        let agg = ConnectionAggregator()
        let conn = connection("Mail", "1.1.1.1", 443)
        await agg.apply(.added(connection: conn))
        await agg.attributePackets([.init(flowKey: conn.fiveTuple.packetFlowKey, pid: 1, inbound: true, bytes: 9)])
        await agg.reset()
        #expect(await agg.usageSnapshot().isEmpty)
    }
}
```

> Before writing the test, confirm the real constructor/initializer names for `Connection`, `Endpoint`, `IPAddress`, `AppIdentity`, and `FiveTuple.packetFlowKey` / `flowKey` in `Sources/MatrixNetModel/` and the existing `ConnectionAggregatorTests.swift`; adjust the helpers to match exactly. The behaviour asserted (accumulate per app+address, survive `.removed`, clear on `reset`) is what matters.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "ConnectionAggregator usage snapshot"`
Expected: FAIL — no member `usageSnapshot`.

- [ ] **Step 3: Write minimal implementation**

In `ConnectionAggregator.swift` add the type, storage, accumulation, accessor, and reset line:
```swift
// Near the other stored properties:
public struct UsageFlowTotal: Sendable {
    public let app: String
    public let address: IPAddress
    public var bytesIn: UInt64
    public var bytesOut: UInt64
}
/// Monotonic per-(app, destination address) packet byte totals. Unlike
/// `packetBytesByConn`, these are NOT dropped on `.removed`, so the Usage tab
/// can account for short-lived flows that open and close between polls.
private var usageByFlow: [String: UsageFlowTotal] = [:]
```

Inside `attributePackets`, after resolving `connection` (the `guard let connection = connections[id]` block), add:
```swift
let address = connection.fiveTuple.destination.address
let usageKey = "\(connection.app.displayName)\u{1F}\(address.description)"
var flow = usageByFlow[usageKey]
    ?? UsageFlowTotal(app: connection.app.displayName, address: address, bytesIn: 0, bytesOut: 0)
if packet.inbound { flow.bytesIn &+= bytes } else { flow.bytesOut &+= bytes }
usageByFlow[usageKey] = flow
```

Add the accessor:
```swift
/// Monotonic per-(app, address) usage totals for the Usage tab (survive close).
public func usageSnapshot() -> [UsageFlowTotal] { Array(usageByFlow.values) }
```

In `reset()`, add: `usageByFlow.removeAll()`

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "ConnectionAggregator usage snapshot"`
Expected: PASS. Then run the full aggregator suite to confirm no regression:
Run: `swift test --filter ConnectionAggregator`

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetCapture/ConnectionAggregator.swift Tests/MatrixNetCaptureTests/ConnectionAggregatorUsageTests.swift
git commit -m "Accumulate monotonic per-flow usage totals in the aggregator"
```

---

## Task 7: Preferences + AppModel orchestration

**Files:**
- Modify: `Sources/MatrixNetModel/Preferences.swift`
- Modify: `App/Sources/AppModel.swift`
- Test: `Tests/MatrixNetModelTests/PreferencesTests.swift` (add cases if the file exists; else create)

**Interfaces:**
- Consumes: `UsageStore`, `UsageAccumulator`, `UsageBucketing`, `UsagePeriod`, `UsageRow`, `ConnectionAggregator.usageSnapshot()`, `GeoIP.country(for:)`, `resolvedHostnames`.
- Produces:
  - `Preferences.usageRetentionDays: Int` (default 90), `Preferences.billingCycleResetDay: Int` (default 1, getter clamps 1...28).
  - `AppModel.usageRows(for period: UsagePeriod) -> [UsageRow]`.
  - Private `AppModel.flushUsage(now:)`, called from the 1 Hz refresh loop, throttled ≥ 30s.

- [ ] **Step 1: Write the failing test (preferences only — AppModel flush is integration-tested via the store)**

Add to `Tests/MatrixNetModelTests/PreferencesTests.swift` (create the file with this content if absent):
```swift
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("Preferences usage settings")
struct PreferencesUsageTests {
    private func make() -> Preferences {
        let suite = "test.\(UInt32.random(in: 1...UInt32.max))"
        return Preferences(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("usage retention defaults to 90 days")
    func retentionDefault() {
        #expect(make().usageRetentionDays == 90)
    }

    @Test("billing cycle reset day defaults to 1 and clamps to 1...28")
    func resetDayClamp() {
        let p = make()
        #expect(p.billingCycleResetDay == 1)
        p.billingCycleResetDay = 40
        #expect(p.billingCycleResetDay == 28)
        p.billingCycleResetDay = 0
        #expect(p.billingCycleResetDay == 1)
    }
}
```
> `UInt32.random` is allowed in tests (the `Math.random` ban is for workflow scripts, not app/test code).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Preferences usage settings"`
Expected: FAIL — no member `usageRetentionDays`.

- [ ] **Step 3: Write minimal implementation**

In `Preferences.swift`, add to `Key`: `case usageRetentionDays = "pref.usageRetentionDays"` and `case billingCycleResetDay = "pref.billingCycleResetDay"`. Add:
```swift
/// How many days of per-app usage history to retain.
public var usageRetentionDays: Int {
    get { defaults.object(forKey: Key.usageRetentionDays.rawValue) as? Int ?? 90 }
    nonmutating set { defaults.set(newValue, forKey: Key.usageRetentionDays.rawValue) }
}

/// Day of the month the billing cycle resets on (clamped to 1...28 so it is
/// valid in every month).
public var billingCycleResetDay: Int {
    get {
        let raw = defaults.object(forKey: Key.billingCycleResetDay.rawValue) as? Int ?? 1
        return min(28, max(1, raw))
    }
    nonmutating set { defaults.set(min(28, max(1, newValue)), forKey: Key.billingCycleResetDay.rawValue) }
}
```

In `AppModel.swift`:
- Add stored properties: `private var usageStore: UsageStore?`, `private var lastUsageSeen: [String: UsageTotals] = [:]`, `private var lastUsageFlush = Date.distantPast`, `private var lastCompactedHour: Date?`.
- Initialize `usageStore = try? UsageStore.persistent()` where `historyStore` is initialized; on launch run `try? usageStore?.prune(olderThan: Calendar.current.date(byAdding: .day, value: -prefs.usageRetentionDays, to: Date()) ?? .distantPast)` and compact past hours: `for h in (try? usageStore?.distinctHours(before: UsageBucketing.hourStart(of: Date(), calendar: .current))) ?? [] { try? usageStore?.compactHour(h, n: 20) }`.
- In `stop()` and at the start of `start()` (where `aggregator.reset()` happens), clear `lastUsageSeen.removeAll()` so deltas restart from a clean baseline.
- Add `flushUsage(now:)` and call it from the refresh loop after fetching `apps`:
```swift
private func flushUsage(now: Date) async {
    guard let usageStore, now.timeIntervalSince(lastUsageFlush) >= 30 else { return }
    lastUsageFlush = now
    let snapshot = await aggregator.usageSnapshot()
    var current: [String: UsageTotals] = [:]
    var meta: [String: ConnectionAggregator.UsageFlowTotal] = [:]
    for flow in snapshot {
        let key = "\(flow.app)\u{1F}\(flow.address.description)"
        current[key] = UsageTotals(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
        meta[key] = flow
    }
    let deltas = UsageAccumulator.deltas(previous: lastUsageSeen, current: current)
    lastUsageSeen = current
    guard !deltas.isEmpty else { return }
    let hour = UsageBucketing.hourStart(of: now, calendar: .current)
    var merged: [String: UsageRow] = [:]
    for (key, delta) in deltas {
        guard let flow = meta[key] else { continue }
        let host = resolvedHostnames[flow.address.description] ?? flow.address.description
        let country = GeoIP.country(for: flow.address) ?? ""
        let rowKey = "\(host)\u{1F}\(country)"
        if var row = merged[rowKey] {
            row.bytesIn += delta.bytesIn; row.bytesOut += delta.bytesOut; merged[rowKey] = row
        } else {
            merged[rowKey] = UsageRow(periodStart: hour, app: flow.app, host: host,
                country: country, bytesIn: delta.bytesIn, bytesOut: delta.bytesOut)
        }
    }
    try? usageStore.accumulate(Array(merged.values))
    if let last = lastCompactedHour, last < hour {
        try? usageStore.compactHour(last, n: 20)
    }
    lastCompactedHour = hour
}
```
- Add: `public func usageRows(for period: UsagePeriod) -> [UsageRow] { (try? usageStore?.fetch(range: period.range(now: Date(), calendar: .current))) ?? [] }`
- Ensure `import MatrixNetStore` is present in AppModel.swift (add if missing).

> Note: `merged` keys by host+country per app would collide across apps; since `flow.app` differs per delta, key the merge by `app\u{1F}host\u{1F}country`. Use `let rowKey = "\(flow.app)\u{1F}\(host)\u{1F}\(country)"`.

- [ ] **Step 4: Run tests + build the app**

Run: `swift test --filter "Preferences usage settings"` → PASS
Run: `swift build` → builds clean (AppModel changes compile in the package? AppModel is in the App target — build via xcodebuild in Task 9; here just ensure MatrixNetModel/Store/Capture compile).

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/Preferences.swift App/Sources/AppModel.swift \
  Tests/MatrixNetModelTests/PreferencesTests.swift
git commit -m "Wire usage flush/compact/prune into AppModel and add usage preferences"
```

---

## Task 8: Usage tab UI + Settings + localization

**Files:**
- Modify: `App/Sources/RootView.swift` (add `.usage` section)
- Create: `App/Sources/UsageView.swift`, `App/Sources/UsagePanels.swift`
- Modify: `App/Sources/SettingsView.swift` (retention + reset-day steppers)
- Modify: `App/Resources/Localizable.xcstrings` (all new strings ×8 langs)

**Interfaces:**
- Consumes: `AppModel.usageRows(for:)`, `UsagePeriod`, `UsageReport`, `Format`, `Theme`, `GeoIP.flag(for:)`, `AppIconResolver`, `Preferences`.

- [ ] **Step 1: Add the `.usage` section to RootView**

In `RootView.Section`: add `case usage` after `case overview`; add to `title` → `"Usage"`; to `symbol` → `"chart.bar.doc.horizontal"`; in detail switch → `case .usage: UsageView()`.

- [ ] **Step 2: Build the Usage UI**

`App/Sources/UsageView.swift` — a `View` with `@Environment(AppModel.self)`, `@State private var period: UsagePeriod = .last7Days`, `@State private var dimension: Dimension = .app`, `@State private var selectedApp: String?`. Compute `rows = model.usageRows(for: period)`. Render: a period `Picker` (segmented) over Today / 7 Days / 30 Days / Cycle (Cycle uses `Preferences(...).billingCycleResetDay`); a hero panel with `UsageReport.totals(rows)` ↓/↑ and a trend area chart from `UsageReport.trend(rows, by: period.trendGranularity, calendar: .current)`; a dimension `Picker` (By App / By Country / By Domain); the corresponding ranked list. All labels via `Text("literal")`. Selecting an app row sets `selectedApp` and filters domain/country.

`App/Sources/UsagePanels.swift` — extract the ranked-row views (`UsageBar` with label + value + proportional bar) and the trend chart to keep each file < 500 lines. Reuse `Theme.inbound`/`Theme.outbound`, `Format.bytes`, `GeoIP.flag(for: countryCode)`. Map `UsageTruncation.otherHost` → `Text("Other")` and empty country → `Text("Unknown")`.

> This step has no unit test (SwiftUI view); all logic it calls is covered by Tasks 1–5. Verify by building and launching in Task 9.

- [ ] **Step 3: Add Settings controls**

In `SettingsView.swift` add a "Usage" section with a `Stepper` bound to `@AppStorage(Preferences.Key.usageRetentionDays.rawValue)` (range 7...365) labelled `"Keep usage history for \(days) days"`, and a `Stepper` bound to `@AppStorage(Preferences.Key.billingCycleResetDay.rawValue)` (range 1...28) labelled `"Billing cycle resets on day \(day)"`. Localize.

- [ ] **Step 4: Localize every new string**

Add each new literal to `App/Resources/Localizable.xcstrings` with translations for de, es, fr, ja, ko, zh-Hans, zh-Hant (en is the base/source). New keys (verbatim): `"Usage"`, `"Today"`, `"7 Days"`, `"30 Days"`, `"Cycle"`, `"By App"`, `"By Country"`, `"By Domain"`, `"Other"`, `"Unknown"`, `"Gathering usage…"`, `"Keep usage history for %lld days"`, `"Billing cycle resets on day %lld"`, plus any section headers used. Run the coverage check.

Run: `python3 scripts/check-localizations.py`
Expected: `All catalog keys translated into: de, es, fr, ja, ko, zh-Hans, zh-Hant`

- [ ] **Step 5: Format, lint, build, commit**

```bash
swiftformat .
swiftlint lint --strict          # expect 0 violations
xcodebuild build -project MatrixNet.xcodeproj -scheme MatrixNet -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
git add App/Sources/RootView.swift App/Sources/UsageView.swift App/Sources/UsagePanels.swift \
  App/Sources/SettingsView.swift App/Resources/Localizable.xcstrings
git commit -m "Add Usage tab, usage settings, and localizations"
```

---

## Task 9: Docs + release (0.1.22)

**Files:**
- Modify: `project.yml` (version ×6), `CHANGELOG.md`, `README.md` + 7 translations, regenerate project.

- [ ] **Step 1:** Bump version in `project.yml` to `0.1.22` / build `23` (MARKETING_VERSION, CURRENT_PROJECT_VERSION, and both App+Widget CFBundleShortVersionString/CFBundleVersion). Run `xcodegen generate`.
- [ ] **Step 2:** Add a `## [0.1.22]` CHANGELOG entry under "Added": the Usage tab (per-app/country/domain reports over today/7/30 days/billing cycle, hourly buckets, 90-day retention).
- [ ] **Step 3:** Add a "Usage reports" bullet to `README.md`'s feature list and mirror it in `README.zh-CN.md`, `README.zh-Hant.md`, `README.ja.md`, `README.ko.md`, `README.fr.md`, `README.de.md`, `README.es.md`.
- [ ] **Step 4:** Full gate: `swiftformat . && swiftlint lint --strict && swift test && python3 scripts/check-localizations.py` (all pass), then Release build.
- [ ] **Step 5:** Commit (no Claude authorship), push, `gh workflow run release.yml -f version=v0.1.22`, `gh run watch <id> --exit-status`, verify appcast `sparkle:version == 23`, then local Developer-ID install.

```bash
git add -A
git commit -m "Release 0.1.22: per-app usage reports"
git push origin main
```

---

## Self-Review

**Spec coverage:** §3.1 pure logic → Tasks 1–4. §3.2 store → Task 5. §3.3 aggregator+AppModel → Tasks 6–7. §3.4 preferences → Task 7. §3.5 UI → Task 8. §6 tests → embedded per task. §7 localization/docs → Tasks 8–9. §8 release → Task 9. §5 edge cases: counter reset (Task 1 deltas), reset() baseline clear (Task 7), DST/hour flooring (Task 1 calendar), cycle clamp (Task 3), prune/compact cadence (Tasks 5,7). Covered.

**Placeholder scan:** No TBD/TODO; each code step shows full code. Two inline corrections are called out explicitly (Task 1 reset test expectation; Task 3 `clampedDay` simplification) — apply them as written.

**Type consistency:** `UsageTotals`/`UsageRow` shared across Tasks 1,4,5,7. `UsageTruncation.otherHost`/`mixedCountry` used in Tasks 2,5,8. `usageSnapshot()`/`UsageFlowTotal{app,address,bytesIn,bytesOut}` defined Task 6, consumed Task 7. `UsagePeriod.range/trendGranularity` defined Task 3, consumed Tasks 7,8. `usageRetentionDays`/`billingCycleResetDay` defined Task 7, consumed Tasks 7,8. Consistent.
