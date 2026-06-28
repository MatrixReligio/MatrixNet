# 功能 A:按应用的时间维度用量报表 — 设计文档

> 状态:已定稿(自主模式)。本文件是 spec,后续 writing-plans 据此生成逐任务 TDD 计划。
> 语言约定:本设计文档为内部文档,用中文;所有面向用户/开源的字符串、注释、DocC 用英文。

## 1. 目标(一句话)
让用户回答"我的流量去哪了":在新的"用量"标签页里,按可选时间段(今天 / 近 7 天 / 近 30 天 / 本计费周期)查看 **Top 应用 / 国家 / 域名** 的字节用量与趋势。

## 2. 决策摘要(已确认)
- **粒度/保留**:小时桶;默认保留 90 天(新偏好 `usageRetentionDays`,可在设置改)。日/周/月/计费周期视图在查询时由小时桶聚合。
- **维度**:应用 × 国家 × 域名。统一一张小时桶表 `UsageBucketRecord {periodStart, app, host, country, bytesIn, bytesOut}`。
- **域名长尾**:每(小时, 应用)保留 Top-N(N=20)域名,长尾合并成合成 host `·other`、country `—`。
- **时间范围**:预设(今天/7天/30天/本计费周期)+ 单一可配置每月重置日(新偏好 `billingCycleResetDay`,默认 1,clamp 1...28)。
- **位置**:新建顶级"用量"标签页(`RootView.Section.usage`,置于 overview 之后)。

## 3. 架构与文件布局
分层:纯逻辑(可 TDD、无 SwiftData/SwiftUI)→ `MatrixNetModel`;持久化(SwiftData)→ `MatrixNetStore`;UI → `App/Sources`;采集接入 → `MatrixNetCapture` + `AppModel`。

### 3.1 纯逻辑(MatrixNetModel,新增)
- `UsageTotals.swift` — `struct UsageTotals: Sendable { var bytesIn: UInt64; var bytesOut: UInt64 }`,加法 `+`。
- `UsageRow.swift` — `struct UsageRow: Sendable { let periodStart: Date; let app: String; let host: String; let country: String; var bytesIn: UInt64; var bytesOut: UInt64 }`(纯值类型;store 的记录映射到它做聚合)。
- `UsageAccumulator.swift` — 纯求差。`static func deltas(previous: [String: UsageTotals], current: [String: UsageTotals]) -> [String: UsageTotals]`:对每个 key 取 `current - previous`,对计数器回退/新 key clamp ≥ 0,忽略 0 增量。key = `"app\u{1F}address"`(聚合器给的稳定键)。
- `UsageBucketing.swift` — `static func hourStart(of date: Date, calendar: Calendar) -> Date`(截到整点)。
- `UsageTruncation.swift` — `static func topN(_ rows: [UsageRow], n: Int) -> [UsageRow]`:按 `app` 分组,每组按 `bytesIn+bytesOut` 取前 n 个 host,其余合并为一行 `host="·other"`、`country="—"`、`periodStart`/`app` 不变、字节求和;组内 ≤ n 时原样返回;各 app 独立。
- `UsagePeriod.swift` — `enum UsagePeriod { case today, last7Days, last30Days, currentCycle(resetDay: Int) }`;`func range(now: Date, calendar: Calendar) -> (start: Date, end: Date)`;`var trendGranularity: TrendGranularity { today → .hour;其余 → .day }`。`currentCycle`:取 ≤ now 的最近"重置日"为 start(重置日 > 当月今天则回上个月;重置日按当月天数 clamp,如 2 月用 28)。
- `UsageReport.swift` — 纯聚合,输入 `[UsageRow]`:
  - `static func totals(_:) -> UsageTotals`
  - `static func byApp(_:) -> [AppUsage]`(`AppUsage{app, totals}`,按总字节降序)
  - `static func byCountry(_:) -> [CountryUsage]`(`CountryUsage{country, totals}`,降序;`·other` 行的 country `—` 归入 "Unknown" 桶)
  - `static func byDomain(_:, app: String?) -> [DomainUsage]`(`DomainUsage{host, totals}`,可按 app 过滤,降序)
  - `static func trend(_:, by: TrendGranularity, calendar:) -> [TrendBucket]`(`TrendBucket{start, totals}`,按小时或天分组、升序、补零空桶可选——v1 不补零,只返回有数据的桶)

### 3.2 持久化(MatrixNetStore,新增)
- `UsageBucketRecord.swift` — `@Model final class UsageBucketRecord { var periodStart: Date; var app: String; var host: String; var country: String; var bytesIn: Int; var bytesOut: Int }`(SwiftData 不支持 UInt64,存 Int;字节量级安全)。
- `UsageStore.swift`(`@MainActor`)— 与 `HistoryStore` 同构:
  - `init(container:)` / `inMemory()` / `persistent()`
  - `func accumulate(_ rows: [UsageRow])`:对每行按 `(periodStart, app, host, country)` 查找;存在则 `bytesIn += / bytesOut +=`(**加法 upsert**,崩溃安全);否则插入。`save()`。
  - `func compactHour(_ hourStart: Date, n: Int)`:fetch 该小时全部记录 → 映射成 `[UsageRow]` → `UsageTruncation.topN` → 删除原记录、插入截断结果。幂等(≤n+1 行时 topN 为恒等)。
  - `func fetch(range: (start: Date, end: Date)) -> [UsageRow]`:`periodStart >= start && < end`,映射为 `[UsageRow]`。
  - `func prune(olderThan cutoff: Date)`:删 `periodStart < cutoff`。
  - `func distinctHours(before: Date) -> [Date]`:用于启动时补压缩。

### 3.3 采集接入(MatrixNetCapture + AppModel)
- `ConnectionAggregator`(改):新增单调、关闭不清除的 per-(app,address) 包级累计。
  - 字段 `private var usageByFlow: [String: UsageFlowTotal]`,key = `"\(app.displayName)\u{1F}\(address.description)"`。
  - `public struct UsageFlowTotal: Sendable { public let app: String; public let address: IPAddress; public var bytesIn: UInt64; public var bytesOut: UInt64 }`(**携带 `IPAddress`**,以便 AppModel 用 GeoIP 解析国家、用 `resolvedHostnames` 解析域名)。
  - 在 `attributePackets` 里:解析到 connection 后,除现有逻辑外,按 key 累加到 `usageByFlow`(`address = connection.fiveTuple.destination.address`)。**`.removed` 不清除 `usageByFlow`**(单调,跨连接关闭存活)。`reset()` 清除。
  - `public func usageSnapshot() -> [UsageFlowTotal]`。
  - 注:`UsageFlowTotal` 仅含进程名 + 地址 + 字节;无需携带完整 `AppIdentity`(图标在 UI 层按名尽力匹配实时连接的 `AppIdentity`,匹配不到用通用符号)。
- `AppModel`(改):
  - 持有 `usageStore: UsageStore?`、`private var lastUsageSeen: [String: UsageTotals] = [:]`、`private var lastUsageFlush = Date.distantPast`、`private var lastCompactedHour: Date?`。
  - 在刷新 tick 内 `flushUsage()`(节流 ≥ 30s):
    1. `let snap = await aggregator.usageSnapshot()`;构造 `current: [String: UsageTotals]`(key=`app\u{1F}address`)。
    2. `let deltas = UsageAccumulator.deltas(previous: lastUsageSeen, current: current)`;`lastUsageSeen = current`。
    3. 把每个 delta key 拆回 app+address;`host = showableHostname(address) ?? address`(用现有 `resolvedHostnames`/`HostnameResolver`),`country = GeoIP.country(for: address) ?? ""`;`periodStart = UsageBucketing.hourStart(now)`;组装 `[UsageRow]`(同 (hour,app,host,country) 合并)。
    4. `usageStore.accumulate(rows)`。
    5. 整点滚动检测:若 `hourStart(now) != lastCompactedHour 的下一个`,对上一个已闭合小时 `compactHour`;更新 `lastCompactedHour`。
  - 启动时一次性:`prune(olderThan: now - usageRetentionDays)` + 对 `distinctHours(before: hourStart(now))` 逐个 `compactHour`(幂等补偿崩溃遗留)。
  - `public func usageRows(for period: UsagePeriod) -> [UsageRow]`:`usageStore?.fetch(range: period.range(now:calendar:)) ?? []`,供视图聚合。

### 3.4 偏好(Preferences,改)
- 新增 `Key.usageRetentionDays = "pref.usageRetentionDays"`(默认 90)、`Key.billingCycleResetDay = "pref.billingCycleResetDay"`(默认 1,getter clamp 1...28)。
- `SettingsView` 增加两项:保留天数 stepper、计费重置日 stepper。本地化。

### 3.5 UI(App/Sources,新增)
- `RootView`:`Section` 加 `case usage`(title `"Usage"`,symbol `chart.bar.doc.horizontal`,置于 `.overview` 后);detail 路由 `UsageView()`。
- `UsageView.swift` + `UsagePanels.swift`(防超 500 行):
  - 顶部:时间段分段控件(Today / 7 Days / 30 Days / Cycle)。
  - Hero:该时段总 ↓/↑(`Format.bytes`)+ 趋势面积图(Swift Charts,`.monotone`,主题色;today 按小时、其余按天)。
  - 维度分段:By App(默认)/ By Country / By Domain。
    - By App:排名横条(图标 via `AppIconResolver` + 名称 + 字节 + 占比%);点击某 app → `selectedApp` 过滤 By Domain / By Country。
    - By Country:旗帜(复用 `GeoIPDatabase.flag`)+ 国名 + 字节;`Unknown` 兜底。
    - By Domain:host 排名 + 字节;`·other` 显示为本地化 "Other"。
  - 空态:数据 < 1 桶时 "Gathering usage…"。
  - 所有文案 `Text("literal")` 走本地化。

## 4. 数据流
PKTAP 包 → `attributePackets` 累加 `usageByFlow`(单调,跨关闭存活)→ AppModel `flushUsage()` 每 ≥30s 取快照求差 → 解析 host/country、按小时分桶 → `UsageStore.accumulate`(加法 upsert)→ 整点 `compactHour`(Top-N)→ 视图 `usageRows(for:)` 取范围 → `UsageReport` 聚合 → 渲染。准确性前提:抓包开启(与连接表一致);关闭抓包时无包级数据则不计(诚实记录于文档)。

## 5. 错误处理与边界
- SwiftData 失败:`try?` 吞掉并不崩溃(与 `HistoryStore` 一致);用量是次要数据。
- 计数器回退 / 监控重启:`deltas` clamp ≥0;`aggregator.reset()` 清 `usageByFlow`,AppModel 下次求差从新基线开始(`lastUsageSeen` 也需在 reset 时清,避免负差被 clamp 成 0 漏算——AppModel 在 stop/start 时同步清 `lastUsageSeen`)。
- 时区/夏令时:全部用 `Calendar.current` 的 `hourStart`/`range`,趋势按本地时间分桶。
- 计费重置日 > 当月天数:clamp 到当月最后一天。
- host 先 IP 后域名导致同地址分裂成两行:接受(v1),功能 B(SNI)改善覆盖。
- 大数据量:查询恒为时间范围扫描(`periodStart` 索引);写入每 ≥30s 一批;压缩每小时一次;清理每日一次。

## 6. 测试策略(TDD,先红后绿)
纯逻辑(MatrixNetModelTests):
- `UsageAccumulator.deltas`:新 key=全量;增长=差值;回退/重启=clamp 0;无变化=空;0 增量忽略。
- `UsageBucketing.hourStart`:截整点(含非零分秒、跨时区用固定 calendar)。
- `UsageTruncation.topN`:取前 n;长尾合并 `·other`/`—`/字节求和;≤n 原样;多 app 独立。
- `UsagePeriod.range`:today;last7/last30 跨度;currentCycle(重置日 < 今天、> 今天回上月、31→当月末 clamp);`trendGranularity` 映射。
- `UsageReport`:byApp 降序;byCountry 分组(Unknown 兜底);byDomain 按 app 过滤;trend 小时 vs 天分组与升序;totals。

持久化(MatrixNetStoreTests,in-memory SwiftData):
- `accumulate`:新插入;同键加法累加;多键。
- `compactHour`:>n 截断为 n+other;幂等(再跑不变)。
- `fetch(range:)`:边界 `[start, end)` 过滤、映射正确。
- `prune`:删旧留新。

采集(MatrixNetCaptureTests):
- `usageSnapshot`:按 app+address 累加;`.removed` 后仍保留;`reset()` 清空。

UI 不做单元测试(SwiftUI 视图),但所有提取的格式化/聚合逻辑均在纯逻辑层覆盖。

## 7. 本地化与开源文档(每次提交同步)
- 新增 UI 字符串(段标题、维度名、空态、设置项、"Other"、"Unknown" 等)全部加入 `Localizable.xcstrings` 的 8 语言(en 基础 + de/es/fr/ja/ko/zh-Hans/zh-Hant);`scripts/check-localizations.py` 须通过。
- 文档:`README.md` 功能列表加"Usage reports";同步 7 个翻译 README 的对应条目;`CHANGELOG.md` 新增条目;`NOTICE` 无新依赖、不变;若新增公开类型,DocC 注释为英文。

## 8. 发版
按既定流程:bump 版本(project.yml 6 处)→ xcodegen → swiftformat + swiftlint --strict + swift test + check-localizations → 构建 App → 更新 CHANGELOG/README(8 语言)→ 提交(无 Claude 署名)→ push → `gh workflow run release.yml -f version=vX.Y.Z` → watch → 校验 appcast(sparkle:version)→ 本地 Developer-ID 安装。

## 9. 阶段 review 关(每阶段结束≥1 次,清零问题再进下一阶段)
设计 → [review] → TDD 计划 → [review] → 实现 → [review:code-reviewer] → 测试 → [review] → 文档/本地化 → [review:check-localizations + 自审] → CI 发版 → [review:appcast + 本地验证]。
