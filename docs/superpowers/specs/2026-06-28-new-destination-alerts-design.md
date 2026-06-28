# 功能 C:被动"新目的地/异常外联"提醒(phoning home)— 设计文档

> 状态:定稿(自主模式)。语言:本文件中文;面向用户/开源字符串、注释、DocC 用英文。

## 1. 目标
把被动观测升级为主动隐私洞察:当一个**已建立基线的应用**首次连到它**从未去过的国家**时,发出**非阻断、可选、限流**的系统通知(Little Snitch 的核心洞察,但无弹窗疲劳、无拦截风险)。

## 2. 选型(最优、低噪声)
- **维度=国家(per app)**:`(app, country)`。比"新主机"低噪声得多(CDN 每个分片都是新主机会刷屏),且抓住最值得警惕的情形——数据流向一个新司法辖区;契合我们 GeoIP/地图身份。新主机维度留作后续。
- **首次运行/多国 CDN 防爆**:每个 app 有 **15 分钟学习窗**——app 首次被观测起 15 分钟内,只**静默学习**(记入基线、不提醒);窗口后出现新国家才提醒。这样多国应用首轮不会刷屏。
- **基线持续构建**:无论提醒开关是否打开,只要在监控就持续把 `(app, country)` 记入基线(知识持续积累);提醒仅在开关打开且判定为 `.alert` 时触发。
- **opt-in**:偏好 `newDestinationAlertsEnabled` 默认关。

## 3. 设计

### 3.1 纯逻辑(MatrixNetModel,新增)
- `NewDestinationDetector.swift`:
  ```
  public enum DestinationVerdict: Sendable, Equatable { case known, learning, alert }
  public enum NewDestinationDetector {
      public static func classify(
          country: String,
          knownCountries: Set<String>,
          appFirstSeen: Date?,
          now: Date,
          learningWindow: TimeInterval
      ) -> DestinationVerdict
  }
  ```
  规则:`country` 为空 → `.known`(忽略未知国家,不打扰);`country ∈ knownCountries` → `.known`;否则 `appFirstSeen == nil`(全新 app)→ `.learning`;`now - appFirstSeen < learningWindow` → `.learning`;否则 → `.alert`。(`.learning`/`.alert` 都应被调用方记入基线;`.alert` 才提醒。)
- 复用现有 `ThreatNotificationPolicy`(per-key 窗 + 全局最小间隔)做提醒限流。

### 3.2 持久化(MatrixNetStore,新增)
- `KnownDestinationRecord.swift`:`@Model { var app: String; var country: String; var firstSeen: Date }`(按 app+country 唯一)。
- `DestinationBaselineStore.swift`(@MainActor):
  - `inMemory()` / `persistent()`(同 HistoryStore/UsageStore 模式)。
  - `func load() -> [String: AppBaseline]`,`struct AppBaseline { var countries: Set<String>; var firstSeen: Date }`(firstSeen = 该 app 各记录的最早值)。
  - `func record(app: String, country: String, at: Date)`:不存在则插入(firstSeen=at)。

### 3.3 编排(AppModel,改)
- 持有 `private var knownDestinations: [String: AppBaseline]`(启动从 `DestinationBaselineStore.load()` 载入)、`destinationBaselineStore`、`newDestinationNotifier`、`private var destinationPolicy = ThreatNotificationPolicy()`(独立实例)。
- 在 publish(或节流 tick)里,对每个 `state == .active` 且能解析出国家(`GeoIP.country(for:)`,仅 `.global` 地址)的连接:
  1. `let app = connection.app.displayName`;`let country = ...`。
  2. `let baseline = knownDestinations[app]`;`verdict = NewDestinationDetector.classify(country:, knownCountries: baseline?.countries ?? [], appFirstSeen: baseline?.firstSeen, now:, learningWindow: 900)`。
  3. 若 `verdict != .known`:`destinationBaselineStore.record(app, country, at: now)` 并更新内存 `knownDestinations`(insert country;若新 app 设 firstSeen=now)。
  4. 若 `verdict == .alert` 且 `preferences.newDestinationAlertsEnabled`:`newDestinationNotifier.notify(app:, country:, host:, now:)`(经 `destinationPolicy.shouldNotify(key: app+country)` 限流)。
- 节流:每个连接每 tick 都判定开销小(集合查找);记入基线只在非 known 时写库(罕见)。可接受。

### 3.4 通知器(App,新增)
- `NewDestinationNotifier.swift`(镜像 ThreatNotifier,@MainActor,UserNotifications):`notify(app:country:host:now:)` 用传入的 `ThreatNotificationPolicy`(由 AppModel 持有并传引用?——改为 Notifier 内部持有自己的 policy,与 ThreatNotifier 一致)。文案:title "New destination"(本地化),body "\(app) reached \(country) for the first time"(host 附后,若有)。`requestAuthorizationIfNeeded`。
- 复用 ThreatNotifier 的授权即可(同一进程已请求过 .alert/.sound),但独立 notifier 更清晰;两者都调用 `UNUserNotificationCenter.requestAuthorization` 幂等。

### 3.5 偏好与设置
- `Preferences.newDestinationAlertsEnabled`(默认 false)。SettingsView General 段加 Toggle + 说明脚注;打开时触发 `newDestinationNotifier.requestAuthorizationIfNeeded()`。本地化。

## 4. 数据流
连接快照 → publish 对每活跃连接解析国家 → `NewDestinationDetector.classify`(对照内存基线 + 学习窗)→ 非 known 记入 `DestinationBaselineStore` + 更新内存 → `.alert` 且开关开 → `NewDestinationNotifier`(限流)→ 系统通知。被动、离线、不拦截。

## 5. 错误处理与边界
- 未知国家(loopback/私有/GeoIP 无果)→ `.known`(忽略,不打扰)。
- 学习窗:全新 app 与首 15 分钟静默,防多国 CDN 首轮刷屏。
- 限流:`ThreatNotificationPolicy`(perKeyWindow 默认 60s、globalMinGap 3s)避免突发洪流;key = `app\u{1F}country`。
- SwiftData 失败 `try?` 吞掉(基线是次要数据)。
- `knownDestinations` 内存随会话增长,有界于 distinct (app,country)(国家基数小),可接受。
- 监控停/重启:基线持久,无需清(知识跨会话累积);内存基线在启动 load。

## 6. 测试(TDD)
- `NewDestinationDetectorTests`(MatrixNetModel):known(国家已知)/ 空国家→known / 全新 app→learning / 窗口内→learning / 窗口后新国家→alert。
- `DestinationBaselineStoreTests`(MatrixNetStore,in-memory):record 去重;load 聚合 per-app countries 与最早 firstSeen;跨实例持久(同 container)。
- `Preferences`:`newDestinationAlertsEnabled` 默认 false + round-trip。
- 通知器/AppModel 编排:不单测 UI/通知;靠 detector+store+policy 覆盖(policy 已有测试)。

## 7. 本地化与开源文档
- 新 UI 字符串:设置 Toggle 标题 + 脚注、通知 title/body → 8 语言;check-localizations 通过。
- README 加"Phoning-home / new-destination alerts"条目(8 语言);CHANGELOG 0.1.24。

## 8. 发版:0.1.24 / build 25,流程同前。

## 9. 阶段 review 关:设计→[review]→计划→[review]→实现→[code-reviewer]→测试→[review]→文档/本地化→[review]→发版→[appcast+本地验证]。
