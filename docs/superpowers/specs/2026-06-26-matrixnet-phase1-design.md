# MatrixNet 一阶段设计文档（Spec）

> 内部文档 · 中文 · 2026-06-26
> 状态：定稿（架构 A′）。本文档为一阶段需求与设计的唯一事实来源。

## 0. 背景与目标

MatrixNet 是一款 **100% 原生 SwiftUI 的 macOS 网络监控 + 深度抓包分析工具**。

经市场调研（HTTP 抓包代理赛道 / 底层抓包与系统监控赛道 / macOS 原生网络 API 可行性，三份报告见对话记录），确定方向为：**以"全系统流量监控"（对标 Little Snitch）为主、"底层数据包深度分析"（对标 Wireshark）为辅**。

一阶段一句话定位：
> 像"活动监视器"一样**开箱即用**地看清"谁在联网"（零授权、与任意代理软件零冲突），又能像 Wireshark 一样把任意一条流挖到**包级**——并且每个包都知道是哪个 App 发的。

### 一阶段范围边界

**IN（一阶段做）**
- 全系统连接级监控（按 App 归类：进程、远端域名/IP、国家、上下行速率、累计字节、连接生命周期）
- 深度数据包抓取与解析（重点协议）+ Follow Stream + 显示过滤 + 十六进制联动
- 连接级 ↔ 包级按 5 元组/PID 关联
- pcapng 导出（喂 Wireshark）
- 连接历史持久化
- 菜单栏常驻 item、首启权限引导（onboarding）
- Developer ID 签名 + 公证 + 直分发
- 开源工程规范（Apache-2.0、CI、文档、lint、测试）
- 世界地图（**可选亮点**，工作量可控则做，否则降级为后续）

**OUT（留二阶段及以后）**
- 拦截 / 防火墙（基于 `NEFilterDataProvider` 的 opt-in 拦截模式）
- HTTPS 明文解密（MITM）
- AI 原生分析（自然语言查询、自动识别 tracker/异常/隐私外发）
- 移动端 / 远程抓包
- 规则引擎
- Wireshark 全量协议 dissector

### 关键非功能需求
- **零冲突**（硬约束）：必须能与机器上任意代理/过滤软件（AdGuard、Surge、Stash、Loon、Little Snitch、LuLu、各类 VPN）**同时运行不冲突**。
- **精致简约的 UI**：严格遵循 macOS HIG，采用 macOS 26 Liquid Glass 设计语言，原生组件、SF Symbols、深浅色、辅助功能。
- **代码质量与开源规范优秀**：模块化、Swift 6 strict concurrency、lint、高测试覆盖、完整文档、规范提交、CI/CD。
- **语言约定**：开源文档 + 公开代码注释 + DocC = 英文；内部文档（本 spec、实现计划）+ 与用户沟通 = 中文。

## 1. 架构：A′（被动优先 · 纯被动双源 · 零冲突）

### 1.1 为什么不用 NetworkExtension（关键决策）

调研结论（见对话中 NE 共存调研报告）修正了一个常见误判：

- macOS 上"按进程归类网络流量"**无需** NetworkExtension。内核通过 `NetworkStatistics.framework`（`nettop` / 活动监视器所用）已经把"每条连接 → PID"在内核层归因好，**无 root、无 entitlement、无 TCC、无轮询竞态**。
- `NEFilterDataProvider` 的唯一卖点（精确每流进程归因）因此并不成立；它反而带来真实冲突风险：AdGuard 官方明示其 NE 模式与 Little Snitch 5 不兼容（同在 socket 层互撞）、多过滤器串行队头延迟、Tahoe 上挂载脆弱、需 entitlement + 系统扩展 + 用户审批。
- `NEPacketTunnel` 系统单例、`NEDNSProxy` 独占、透明代理同层互撞 —— 都是"抢路由/抢流"的独占资源，监控类需求用它们得不偿失。

→ **结论：一阶段零 NetworkExtension。** 用纯被动内核观测，完美满足"零冲突"硬约束。拦截能力（二阶段）届时再以 opt-in 的 `NEFilterDataProvider` 拦截模式叠加，并提示与 AdGuard NE 模式的潜在冲突。

### 1.2 进程模型（两进程，最小特权）

```
┌─────────────────────────────────────────────────────┐
│  MatrixNet.app  (SwiftUI, 非沙箱, Hardened Runtime)   │
│  ├─ 连接监控: NetworkStatistics (NStatManager*)        │  ← 无需特权, 进程内
│  ├─ 关联引擎 / 协议解析 / 持久化 / pcapng / UI         │
│  └─ XPC client ───────────────────────┐               │
└───────────────────────────────────────┼───────────────┘
                                         │ XPC（原始包流 + 控制）
┌─────────────────────────────────────────▼─────────────┐
│ com.matrixreligio.matrixnet.helper (root daemon)       │  ← SMAppService 注册
│  └─ 唯一职责: PKTAP/BPF 抓原始包(en0 + utun*), 不解析    │     最小特权
└─────────────────────────────────────────────────────────┘
```

- **连接监控在主 App 内**（NStat 无需 root/扩展）→ 开 App 即可看到"谁在联网"，第一屏就有价值。
- **抓包用一个 root helper**，只负责"抓"。**协议解析放回非特权主 App**：处理不可信网络数据的攻击面绝不放在 root 进程（安全工程最佳实践）。
- 零 NetworkExtension、零系统扩展、零 entitlement。

### 1.3 模块化（Swift Package + Xcode 目标）

核心逻辑以本地 SwiftPM 包形式存在（便于 `swift test` 与 CI 的 TDD）；App 与 Helper 为 Xcode 目标（XcodeGen `project.yml` 生成），依赖该本地包。

| 模块 | 类型 | 职责 | 可测试性 |
|---|---|---|---|
| `MatrixNetModel` | SwiftPM lib | 领域模型(Connection/Packet/AppIdentity/FiveTuple/ProtocolTree) + 5元组/PID 关联引擎 | 纯逻辑，高 |
| `MatrixNetDissection` | SwiftPM lib | 协议解析器（纯函数，输入字节→协议树）+ Follow Stream 重组 | 喂黄金 pcap，高 |
| `MatrixNetPcap` | SwiftPM lib | pcapng 读写（导出/导入回放，含 PKTAP 进程元数据块） | 读写往返，高 |
| `MatrixNetCapture` | SwiftPM lib | 捕获抽象：`ConnectionMonitoring` / `PacketCapturing` 协议 + NStat 绑定 + helper XPC 客户端实现。**私有框架绑定隔离在此** | 协议可 mock |
| `MatrixNetStore` | SwiftPM lib | 持久化（SwiftData 连接历史 + pcap 文件 ring buffer 管理） | 中 |
| `MatrixNetGeoIP` | SwiftPM lib | 本地 GeoIP 查询（开源许可友好库） | 高 |
| `MatrixNetXPC` | SwiftPM lib | App ↔ Helper 的 XPC 协议契约（共享） | 契约测试 |
| `MatrixNetHelper` | Xcode target | root helper daemon（PKTAP 抓取） | 集成 |
| `MatrixNet` (App) | Xcode target | SwiftUI 界面层 | UI/快照 |

依赖方向：UI/App → (Capture, Store, Dissection, Pcap, GeoIP, Model)；Capture/Store/Dissection/Pcap/GeoIP → Model；Helper → XPC（+ 系统 BPF）；App → XPC。无环。

## 2. 数据流

1. **连接级**：`NStatManager` 流式回调（source added / counts / removed）→ `ConnectionMonitor` 归一化为 `Connection`（PID/App、5 元组、字节、状态、起止）→ 关联引擎 → 实时连接列表 + 历史存储。
2. **包级**：用户开启抓包 → 主 App 经 XPC 令 helper 启动 PKTAP（带 BPF 过滤）→ helper 把原始包（**含每包 PID/进程名/方向**）流回 → `MatrixNetDissection` 解析为协议树 → 包列表/详情/hex → 可写入 pcapng。
3. **关联**：`Packet` 的 5 元组/PID ↔ `Connection` → "某 App 的连接 + 它的原始包"统一视图。
4. **DNS 富化**：从抓到的 DNS 响应建立 `IP → 域名` 映射表，回填连接的远端主机名（补足 NStat 只有 IP 的情况）。

## 3. UI/UX 设计

### 3.1 设计原则
- 严格遵循 **macOS HIG**；采用 macOS 26 **Liquid Glass** 设计语言。
- 全程**原生组件**：`NavigationSplitView`、`Table`、`Inspector`、原生工具栏 / 搜索。
- **SF Symbols** + 系统字体（正文 SF Pro，十六进制/等宽用 SF Mono）。
- 原生**深/浅色**与**辅助功能**（动态字体、VoiceOver、对比度）。
- 信息密度对进阶用户友好但不杂乱（反 Wireshark 默认满屏噪声）。

### 3.2 界面蓝图
- **侧边栏**：概览 · 连接 · 抓包分析 · 会话历史 · 设置
- **概览/仪表盘**：实时总速率、Top App / Top 域名、（可选）世界地图连接落点
- **连接视图（②主）**：按 App 分组的实时连接 `Table`（App 图标·进程·远端域名/IP·国旗·上下行速率·累计字节·连接数），可搜索/排序/过滤，`Inspector` 看连接详情
- **抓包分析（③深）**：Wireshark 式三栏（包列表 / 协议详情树 / 十六进制）+ 显示过滤器 + Follow Stream + 按 App/连接联动过滤；开始/停止·选接口·BPF 过滤
- **菜单栏常驻 item**：实时网速 + 最近连接 + 快速开关
- **导出**：选中包/会话 → pcapng

### 3.3 "③深度"的务实定义
一阶段把 **Ethernet / IPv4 / IPv6 / TCP / UDP / ICMP / DNS / TLS(握手·SNI·证书) / HTTP-1.1** 做扎实 + Follow Stream + hex 联动 + 显示过滤，**不**追求 Wireshark 全量 dissector。

## 4. 持久化
- 连接历史 → **SwiftData**（隐私用户回看"昨天哪个 App 连了哪"）。
- 原始包 → 磁盘 **pcapng 文件**（按抓包会话；设大小/时长上限的 ring buffer；不进数据库）。
- 设置 → `UserDefaults`。

## 5. 首启 / 权限 / 安装（优雅降级）
- **连接监控**：零授权，开 App 即用。
- **深度抓包**：需 root helper → 引导式授权安装 `SMAppService` daemon（一次系统授权）。未授权时连接监控全部可用，仅抓包灰显 + 重试引导。
- 引导式 onboarding：清楚说明每项权限"为什么需要、装了能多看什么"。

## 6. 签名 / 分发
- 签名主体：`Developer ID Application: MatrixReligio LLC`（Team ID `4DUQGD879H`）。
- Hardened Runtime + **Notarization**（app + helper 都签）；helper 经 `SMAppService` 注册并校验签名（Team ID + bundle id）。
- **不开 App Sandbox**（NStat 的 `PF_SYSTEM` 控制 socket 与 BPF 需要）。
- **无 NE entitlement**（A′ 不用 NE）。
- 公证用 App Store Connect API Key `AuthKey_F6M57PP394`（Individual Key 模式 `--key`+`--key-id`）。
- 分发：GitHub Releases（公证 .dmg）+ 可选 Homebrew cask。

## 7. 错误处理 / 边界
- helper 安装失败/被拒 → 仅连接监控可用，抓包重试引导。
- NStat 私有符号在新 OS 失效 → 隔离模块捕获、降级提示、不崩溃；CI 跨大版本回归。
- BPF 缓冲溢出 → 显示丢包计数（像 Wireshark dropped）。
- VPN 在跑 → 自动 en0 + utun* 双抓并在 UI 标注接口；外层(en0 加密)/内层(utun 明文)归因差异需真机实测核对。
- 大流量 → 连接列表虚拟化；抓包背压 + 写盘；解析在后台 actor。
- **Swift 6 strict concurrency**：捕获/解析 actor 隔离，UI 主 actor。

## 8. 测试策略

测试要求（用户强调）：**必须充分**；**用 macOS 最新自动测试框架**；**重点覆盖边界与竞争条件**。

### 8.1 框架
- 统一使用 **Swift Testing**（`import Testing`；`@Test`、`#expect`、`#require`、`@Test(arguments:)` 参数化、`confirmation` 异步事件计数、`@Suite`、tag/trait、`.timeLimit`）。仅在 Swift Testing 暂不支持的场景（如某些 UI/性能基线）回落 XCTest（`XCTestExpectation`、`measure`、`XCUITest`）。
- 协议解析用**参数化测试**批量喂多份样本（黄金 pcap + 构造畸形输入）。

### 8.2 单元
- `MatrixNetDissection` 喂黄金 pcap 断言协议树（回归）；`MatrixNetPcap` 读写往返；关联引擎 5元组/PID；DNS 富化；GeoIP 查询。

### 8.3 边界 / 畸形输入（重点）
对每个解析器系统性覆盖：空输入 / 零长字段 / 单字节 / 截断在每个头部边界 / 长度字段超过缓冲（整数溢出、越界）/ 长度字段为 0 或最大 / 非法版本号与协议号 / 选项 TLV 越界或自指 / IP 分片与重组边界 / TCP 序号回绕 / 重复与乱序 / 巨型与最小 MTU / 非对齐偏移。原则：**任何畸形输入都不得崩溃、不得无限循环、不得越界读**，要么返回部分解析要么明确报错。用 fuzz 风格的随机/变异输入做补充。

### 8.4 并发 / 竞争条件（重点）
- **actor 隔离**：捕获摄入 actor、关联引擎 actor 在高并发下的正确性。
- **双源并发**：NStat 连接事件流与 PKTAP 包流**同时高速摄入**时的关联正确性、无数据竞争、无丢失/重复。
- **生命周期竞态**：连接 added/counts/removed 与包到达的乱序/交错；PID 复用；进程退出时身份快照保留。
- **压力测试**：上万并发连接 / 高 PPS 包流，断言不丢序、内存有界（ring buffer）、背压生效。
- **CI 加 ThreadSanitizer 专用 job**（`swift test --sanitize=thread`）跑并发测试；本地解析器另跑 AddressSanitizer/UBSan 跑畸形输入集。
- 用 `confirmation(expectedCount:)` 验证异步回调精确次数；用 `.timeLimit` 防死锁挂起。

### 8.5 集成
- `ConnectionMonitor` 对（录制 / mock 的）NStat 回调聚合；helper XPC 协议契约（编解码往返、断连重连、权限缺失降级）。

### 8.6 E2E / 手动
- 真机联网验证按 App 归类正确、pcapng 能被 Wireshark 打开、VPN 双抓正确。

### 8.7 CI
- GitHub Actions：build + SwiftLint + SwiftFormat 校验 + 单元/集成测试（Swift Testing）+ 独立 ThreadSanitizer job + 代码覆盖率报告（阈值门）；release workflow 做签名 + 公证。

## 9. 里程碑（增量交付）
- **M1** 连接监控可用（NStat + 连接表 UI + 历史）
- **M2** 抓包 + 解析（helper + PKTAP + dissector + 三栏 UI）
- **M3** 关联 + Follow Stream + pcapng 导出 + DNS 富化
- **M4** 打磨（地图 / 菜单栏 / onboarding）+ 签名公证 + CI + 文档发布

每个里程碑/阶段结束做 code-review（自动子 agent，必要时叠加 codex 独立复审），按 receiving-code-review 流程修完再进下一阶段。

## 10. 工作量热点（如实标注）
1. 协议解析器 + Follow Stream（最大块）
2. PKTAP helper + XPC + 签名/公证链路（特权组件 + 分发）
3. NetworkStatistics 私有框架绑定（跨版本脆弱，需隔离 + 回归）
4. Wireshark 式三栏 UI + 显示过滤 DSL
5. 世界地图（可选亮点，可砍）

## 11. 关键风险与缓解
| 风险 | 缓解 |
|---|---|
| NStat 私有框架跨 OS 失效 | dlopen 高层符号、藏 protocol 后、CI 逐大版本回归、降级到 proc_pidfdinfo 补充 |
| PKTAP 对 VPN 内外层归因不一致 | en0 + utun* 双抓、真机实测核对 `frame.darwin.process_info` |
| 公证缺 issuer（若 Individual Key 不适用） | 改用 store-credentials + issuer；必要时由用户提供 |
| helper 授权需用户手动点（无法全自动） | onboarding 引导 + 状态检测 + 重试 |
| 大流量性能 | 背压、虚拟化列表、后台 actor 解析、BPF 内核过滤 |
