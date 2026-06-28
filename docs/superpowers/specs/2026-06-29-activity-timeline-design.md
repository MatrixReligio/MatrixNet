# 功能 ⑤ 设计:per-app 活动时间线("哪个应用,什么时候,在网络上活跃")

> 本批第 5 个(收尾)子项目。内部设计文档(中文)。目标版本:**1.6.0(build 37)**。

## 1. 目标与价值

把已经按小时持久化的用量数据(`UsageStore`)可视化为**每个应用的活动时间线**:在一个可选时间窗(最近 24 小时 / 7 天)内,每个应用一条横向时间条,按小时显示其网络流量强度。回答:"哪个应用在我没看的时候(半夜、后台)还在联网?它的活动呈什么节律?"

- 一眼看出**后台/夜间活动**:某 App 凌晨 3 点规律性外联。
- 看出**活动节律**:工作时段密集 vs 全天均匀(常驻心跳)。
- 与已有"用量"(总量排行)互补:用量回答"谁用得多",时间线回答"谁在何时活跃"。

竞品空白:Activity Monitor/nettop 只有瞬时值,无 per-app 历史时间线;没有 macOS 工具把"进程 × 时间"的网络活动画成时间线。数据**已在手**(UsageStore 小时桶),零额外采集。

## 2. 范围与边界

- **非 capture-only**:完全复用 `UsageStore` 的按小时桶(常规监控即累积),无需抓包。
- 粒度:**小时桶**(现有持久化粒度)。窗口:最近 24h(24 桶)/ 7d(168 桶,展示时可按天聚合或保持小时)。本版做 24h 与 7d 两档。
- 强度度量:每桶 `bytesIn+bytesOut`;显示用对数或按行最大值归一,避免大流量应用压扁其余。
- 不做秒级/分钟级时间线(无该粒度数据);不做跨设备。

## 3. 架构与组件(纯核心 spike-first,复用现有用量)

数据流:
```
UsageStore.fetch(range:) -> [UsageRow]{periodStart(hour), app, bytesIn/out}
   → ActivityTimeline.build(rows:, window:) (纯) → per-app 对齐到窗口小时桶的序列
   → AppModel.activityTimeline(period:) → 时间线视图(每应用一条热力条)
```

### 3.1 纯核心(MatrixNetModel,`swift test` 独立验证)
- **`struct ActivityBucket: Sendable, Equatable`**:`{ start: Date, bytes: UInt64 }`。
- **`struct AppActivityRow: Sendable, Equatable`**:`{ app: String, buckets: [UInt64], total: UInt64 }`(buckets 与窗口小时刻度一一对齐,无活动为 0)。
- **`struct ActivityTimeline: Sendable, Equatable`**:`{ hours: [Date], rows: [AppActivityRow] }`(hours 为窗口内每个小时桶起点,升序;rows 按 total 降序)。
- **`enum ActivityTimelineBuilder`**:`static func build(rows: [UsageRow], hours: [Date]) -> ActivityTimeline`。把每行 `bytesIn+bytesOut` 累加到 `(app, hourBucket)`,再对每个 app 生成与 `hours` 对齐的 `[UInt64]`(缺失补 0),按 total 降序。`hours` 由调用方按窗口与日历生成(复用 `UsageBucketing.hourStart` 对齐)。纯、可 TDD(合成 UsageRow)。

### 3.2 归属与读取(AppModel)
- `AppModel.activityTimeline(period: UsagePeriod, now: Date = Date()) -> ActivityTimeline`:用 `usageRows(for:)` 取该窗口的行;按窗口/日历生成 `hours`(每小时一格,24h=24 格;7d 可按现有粒度生成 168 小时格或按天 7 格——本版 24h 用小时、7d 用按天聚合 7 格,通过传入对应的 `hours` 刻度实现,builder 通用)。无新持久化。

### 3.3 UI
- 新增**时间线**呈现:放在「用量」标签内作为一个模式切换(总量 / 时间线),或新增侧栏「时间线」项。**决定**:作为「用量」内的视图模式(段控:用量 / 时间线),复用已有窗口选择(24h/7d),避免新增顶层标签。
- 每个应用一行:左侧 App 图标+名,右侧一条由小格组成的热力条(格强度 = 该小时字节,按行最大值或全局对数归一上色),hover 显示该小时具体字节与时间。按 total 降序,限 Top N(如 30),其余折叠"其他"。
- 空态:无用量数据 → 引导"开始监控后,应用的活动会在这里按小时显示"。

## 4. 错误处理与降级
- 无数据/空窗口 → 空 `rows`,UI 空态。
- 应用在某些小时无活动 → 该格为 0(不画/最浅色)。
- builder 为纯函数、总返回有意义值,无抛错。

## 5. 测试策略(TDD)
### 第 0 阶段:ActivityTimelineBuilder 纯核心 spike(`swift test`,不动 app)
- 合成 UsageRow:app A 在 h0、h2 有流量,h1 无 → A.buckets == [x,0,y],total==x+y。
- 多 app 按 total 降序;同 app 多 host 行在同一小时桶累加。
- hours 对齐:行的 periodStart 不在 hours 刻度内 → 忽略;hours 含无任何行的小时 → 该列各 app 为 0。
- bytesIn+bytesOut 合计。
### 接入阶段(影响版本)
- `AppModel.activityTimeline(period:)` 用 `usageRows` + 生成 hours;时间线视图渲染 + 空态;回归不受影响。
- 全程 Swift Testing、零警告、双 linter、8 语言、界面核验(`scripts/smoke.sh` 正签启动)。
- **发版前全量回归**:swift test + 构建产物/数据集校验 + smoke 启动确认时间线渲染。

## 6. 交付与发版
spike 绿 + review → 接入 → code-reviewer 清零 → 测试全绿 + 界面核验(smoke.sh)→ 文档(README ×8 "per-app 活动时间线" bullet、CHANGELOG、新 UI 串 8 语言)→ 版本 1.6.0/37 → 提交(无 Claude 署名)→ push → Release(`gh workflow run release.yml -f version=v1.6.0`)→ appcast(sparkle:version=37)→ 验证 DMG 数据集 + 本地 Developer-ID 安装。

## 7. 自审清单
- 无 TBD;范围单一(读现有小时用量 → per-app 时间线;无新采集、无新持久化)。
- 复用:`UsageStore.fetch`/`usageRows`、`UsagePeriod`、`UsageBucketing.hourStart`;builder 纯函数。
- 非 capture-only 明确;命名一致:`ActivityTimeline`/`AppActivityRow`/`ActivityBucket`/`ActivityTimelineBuilder.build`/`AppModel.activityTimeline(period:)`。
- 界面核验用 `scripts/smoke.sh`(Developer-ID 正签),杜绝 TCC 弹窗。
