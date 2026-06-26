# MatrixNet 一阶段实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> 内部文档 · 中文。配套 spec：`docs/superpowers/specs/2026-06-26-matrixnet-phase1-design.md`。

**Goal:** 实现 MatrixNet 一阶段——纯被动、与任意代理软件零冲突的 macOS 全系统网络监控（按 App 归类）+ 深度数据包分析，Developer ID 公证直分发，Apache-2.0 开源。

**Architecture:** 架构 A′（被动优先）。连接级监控用 `NetworkStatistics`(`NStatManager*`) 私有框架（内核归因 PID，无 root/无 NE/零冲突）；深度抓包用 PKTAP/BPF，经一个最小特权 root helper（`SMAppService`）回流主 App 解析；两源按 5 元组 + PID 关联。两进程：SwiftUI 主 App（非沙箱）+ helper daemon。

**Tech Stack:** Swift 6（strict concurrency）、SwiftUI（macOS 26 Tahoe / Liquid Glass）、SwiftData、Swift Testing、SwiftPM（核心库）+ XcodeGen（App/Helper 目标）、SwiftLint/SwiftFormat、GitHub Actions、`codesign`/`notarytool`。

## Global Constraints

- 部署目标 macOS 26.0+；Swift 6 语言模式（strict concurrency）；不开 App Sandbox；Hardened Runtime + Notarization。
- **零冲突**：一阶段绝不使用任何 NetworkExtension provider。
- **零警告**：`swiftlint --strict` 退出码必须为 0；`swift build` 无任何警告；CI 将 lint 警告视为错误。
- **TDD**：任何生产代码前先有失败测试；测试用 Swift Testing；覆盖边界 + 并发竞态；并发测试在 CI 跑 `--sanitize=thread`。
- 语言：开源文档 + 公开代码注释 + DocC = 英文；内部文档 + 与用户沟通 = 中文。
- 不确定的 macOS API 必须查证（context7 / Apple 官方文档 / XNU 头文件），不得臆测。
- 签名：`Developer ID Application: MatrixReligio LLC` (Team ID `4DUQGD879H`)；Bundle ID `com.matrixreligio.matrixnet`，helper `com.matrixreligio.matrixnet.helper`。公证 API Key `AuthKey_F6M57PP394`（不入库）。
- 提交规范 Conventional Commits；提交身份 `Jim Ho <jim.ho@matrixreligio.com>`；每个 bite-sized 任务后提交；每阶段结束 code-review 门。

---

## 文件结构

```
Package.swift                          # SwiftPM 核心库（逐模块加入）
project.yml                            # XcodeGen：App + Helper 目标
.swiftlint.yml / .swiftformat / .gitignore
Config/*.xcconfig                      # 签名配置（敏感值不入库）
Sources/
  MatrixNetModel/                      # 领域模型 + 关联引擎（DONE）
  MatrixNetDissection/                 # 协议解析（L2-L4 DONE；L7 待做）
  MatrixNetPcap/                       # pcapng 读写
  MatrixNetXPC/                        # App↔Helper XPC 协议契约（共享）
  MatrixNetCapture/                    # NStat 绑定 + PKTAP helper 客户端（私有框架隔离于此）
  MatrixNetGeoIP/                      # 本地 GeoIP
  MatrixNetStore/                      # SwiftData 历史 + pcap 文件管理
App/Sources/                          # SwiftUI App（@main、视图、视图模型）
App/MatrixNet.entitlements
Helper/Sources/                       # root helper（PKTAP 抓取 + XPC 服务）
Helper/MatrixNetHelper.entitlements
Tests/<Module>Tests/                  # Swift Testing
scripts/                              # build / sign / notarize / dmg
.github/workflows/ci.yml / release.yml
```

依赖方向：App → (Capture, Store, Dissection, Pcap, GeoIP, XPC, Model)；Capture → (Model, XPC)；Dissection/Pcap/Store/GeoIP → Model；Helper → XPC。无环。

---

## 阶段与任务

> 状态图例：✅DONE ⏳进行中 ⬜待做。已完成任务保留以记录契约。

### 阶段 0：脚手架 + 开源文档 ✅DONE
- ✅ SwiftPM、XcodeGen 布局、SwiftLint/SwiftFormat、.gitignore
- ✅ 英文开源文档（README/LICENSE Apache-2.0/NOTICE/CONTRIBUTING/CODE_OF_CONDUCT/SECURITY/CHANGELOG/docs/ARCHITECTURE）
- ✅ spec 落盘
- **Review 门**：✅（脚手架随代码一并审查）

### 阶段 1：MatrixNetModel ✅大部分DONE + 修复项
**Produces（已定契约）**：`IPAddress`、`TransportProtocol`、`Endpoint`、`FiveTuple`/`FlowKey(方向无关)`、`AppIdentity`、`Packet(isTruncated)`、`Connection(totalBytes/updateCumulativeCounts 单调)`、`actor FlowCorrelator`。
- ✅ 全部类型 + 30 测试 + TSan 无竞争。
- ⬜ **Task 1.R1（修 review H1：PID 索引一致性 bug）**
  - **Files:** Modify `Sources/MatrixNetModel/FlowCorrelator.swift`；Test `Tests/MatrixNetModelTests/FlowCorrelatorTests.swift`
  - [ ] Step1 写失败测试 `pidFallbackSurvivesNewerRemoval`：register(older pid=501,FK1) + register(newer pid=501,FK2) + remove(newer) → `connectionID(forPacketFlow: 无关key, pid:501)` 应 == older.id
  - [ ] Step2 跑测试，预期 FAIL（当前返回 nil）
  - [ ] Step3 实现：`latestConnectionIDByPID: [Int32: UUID]` 改为 `connectionIDsByPID: [Int32: [UUID]]`（注册 append、remove 删除）；`connectionID(forPacketFlow:pid:)` 回退时返回该 pid 列表中最后一个仍存在于 `connectionsByID` 的 id；register 覆盖 flowKey 时若旧 id 不再被任何 flowKey/pid 引用则从 `connectionsByID` 清理（避免泄漏）
  - [ ] Step4 跑全 Model 测试 + `--sanitize=thread`，预期 PASS
  - [ ] Step5 commit `fix(model): keep older same-PID connections after newer removed`
- ⬜ **Task 1.R2（补边界/并发测试：review M4/M5/M6/M7/L1-L4）**
  - [ ] IPv4-mapped IPv6：`IPAddress("::ffff:192.0.2.1")` 解析为 v6；且 `!= IPAddress("192.0.2.1")`（注释：归一化责任在 Capture 层）；新增 `IPAddress.unmappedIPv4` 计算属性把 `::ffff:a.b.c.d` 归一化为 v4 并测试
  - [ ] zone id 拒绝：`"fe80::1%en0"`、`"fe80::1%"` 加入 rejectsMalformed；文档注释补"Zone IDs not supported"
  - [ ] `totalBytes` 回绕注释 + 溢出测试（`UInt64.max + 1 == 0`）；`updateCumulativeCounts` 增加 `packetsIn/packetsOut` 单调更新（默认参数不破坏现有调用）
  - [ ] 并发 register+remove 交错压力测试，断言索引一致
  - [ ] 端口 0/65535 方向无关、自连接 FlowKey、`AppIdentity.unknown`、`Packet` data>original 行为测试
  - [ ] commit `test(model): boundary + concurrency coverage from review`
- **Review 门**：阶段 1 修复完成后再跑一次 code-review 确认 H1 已解决。

### 阶段 2：MatrixNetDissection
**Produces（已定契约）**：`ByteReader`(边界检查)、`DissectionField/Node`、`DissectedPacket(layers/fiveTuple/summary/protocolPath/highestProtocol)`、`LinkLayerType`、`PacketDissector.dissect(_:linkType:)`。
- ✅ ByteReader + Ethernet/IPv4/IPv6/TCP/UDP + 编排器 + 22 测试（含截断 fuzz）。
- ⬜ **Task 2.1 ICMP/ICMPv6 基础解析**
  - **Files:** Create `Sources/MatrixNetDissection/ICMPDissector.swift`；Test 追加
  - [ ] 写失败测试：ICMP echo request（type 8）→ layer "ICMP" + 字段 type/code；ICMPv6 同理
  - [ ] 跑 FAIL → 实现（type/code/checksum，echo 的 id/seq）→ 跑 PASS → commit
- ⬜ **Task 2.2 DNS 解析（最重要的 L7）**
  - **Files:** Create `Sources/MatrixNetDissection/DNSDissector.swift`
  - **Interfaces Produces:** `struct DNSMessage { let id; let isResponse; let questions: [DNSQuestion]; let answers: [DNSResourceRecord] }`；`DNSResourceRecord { name; type; ip: IPAddress? }`；供 Capture 层做 DNS 富化
  - [ ] Step1 失败测试：用 `dnsQueryOverEthernet` fixture，dissect 后存在 layer "DNS"，question name=="example.com" type=="A"
  - [ ] Step2 失败测试（响应）：构造 A 记录响应 fixture，answers 含 ip
  - [ ] Step3 边界测试：name 压缩指针（0xC0 偏移）、指针自指/成环（必须不死循环，设跳转上限）、截断、超长 label（>63）、QDCOUNT 撒谎
  - [ ] Step4 跑 FAIL → 实现 DNS header(12B) + QNAME 解析（支持压缩指针，带跳转计数上限防环）+ question/answer；A/AAAA 记录提取 IPAddress → 跑 PASS
  - [ ] commit `feat(dissection): DNS with compression-pointer safety`
- ⬜ **Task 2.3 TLS 解析（握手/SNI/证书摘要）**
  - **Files:** Create `Sources/MatrixNetDissection/TLSDissector.swift`
  - [ ] 失败测试：ClientHello fixture → layer "TLS"，字段 "Handshake Type"=="Client Hello"，SNI=="example.com"，version
  - [ ] 失败测试：ServerHello / Certificate（仅取长度与数量，不解 X.509 字段）/ ApplicationData（仅标记加密）
  - [ ] 边界：record 长度撒谎、握手跨多 record、扩展越界、非 TLS 端口上的 TLS（按内容嗅探 0x16 0x03）
  - [ ] 实现 TLS record(type/version/length) + handshake(type/length) + ClientHello 扩展解析取 SNI（server_name 扩展）→ PASS → commit
- ⬜ **Task 2.4 HTTP/1.1 解析**
  - **Files:** Create `Sources/MatrixNetDissection/HTTPDissector.swift`
  - [ ] 失败测试：请求 "GET /path HTTP/1.1\r\nHost: x\r\n\r\n" → layer "HTTP"，method/target/version/headers；响应 "HTTP/1.1 200 OK"
  - [ ] 边界：无 \r\n 结尾、超长头、二进制混入（非 HTTP）、大小写头名、折叠头
  - [ ] 实现起始行 + 头解析（只解析头，不重组 body）→ PASS → commit
- ⬜ **Task 2.5 应用层接入编排器（按端口 + 内容嗅探）**
  - **Files:** Modify `PacketDissector.swift`
  - [ ] 失败测试：dnsQuery fixture → protocolPath 末尾含 "DNS"；TLS-on-443 → "TLS"；HTTP-on-80 → "HTTP"
  - [ ] 实现：transport 之后按 (dstPort/srcPort==53→DNS, ==443 或内容 0x16 0x03→TLS, ==80 或起始行像 HTTP→HTTP) 选 app 解析器；失败回退不崩溃 → PASS → commit
- ⬜ **Task 2.6 Follow Stream（TCP 流重组）**
  - **Files:** Create `Sources/MatrixNetDissection/StreamReassembler.swift`
  - **Interfaces Produces:** `struct StreamReassembler { mutating func add(_ packet, payload) ; func bytes(for direction) -> [UInt8] }`，按 flowKey + seq 排序去重重组双向字节流
  - [ ] 失败测试：乱序到达的 3 个 TCP 段按 seq 重组为连续字节；重传重复段去重；缺洞用占位/标记
  - [ ] 边界：seq 回绕（UInt32 w鄃rap）、SYN 相对序号、空段、重叠段
  - [ ] 实现 → PASS → commit
- **Review 门**：阶段 2 完成后 code-review（重点 DNS 压缩指针防环、TLS/HTTP 边界、流重组 seq 回绕）。

### 阶段 3：MatrixNetPcap
**Produces:** `PcapNGWriter`（写 SHB/IDB/EPB + 进程名注释选项）、`PcapNGReader`（回放）。pcapng 选 LINKTYPE_ETHERNET(1) 或 PKTAP(258)。
- ⬜ **Task 3.1 pcapng 写**
  - **Files:** Create `Sources/MatrixNetPcap/PcapNGWriter.swift`；加 Package 目标
  - **Interfaces:** `final class PcapNGWriter { init(linkType:) ; func makeHeader() -> [UInt8] ; func encode(_ packet: Packet) -> [UInt8] }`（纯字节生成，便于测试；文件写入由 Store 层负责）
  - [ ] 失败测试：header 以 SHB magic `0x0A0D0D0A` + byte-order magic `0x1A2B3C4D` 开头；IDB linktype 正确
  - [ ] 失败测试：EPB 包含时间戳（高低 32 位）、caplen/len、对齐到 4 字节、block total length 首尾一致
  - [ ] 边界：空 payload、超长、非 4 对齐 padding、caplen<len（截断包）
  - [ ] 实现 → PASS → commit
- ⬜ **Task 3.2 pcapng 读（往返）**
  - **Files:** Create `Sources/MatrixNetPcap/PcapNGReader.swift`
  - [ ] 失败测试：writer 产出的字节 → reader 解析回等价 `Packet` 列表（时间戳/长度/字节一致）
  - [ ] 边界：截断文件、未知 block 类型跳过、错误 magic 报错不崩溃、大小端
  - [ ] 实现 → PASS → commit
  - [ ] **互操作验证**：把样例写成 .pcapng 用 `tshark -r` 或 `capinfos` 验证可被 Wireshark 工具链识别（脚本 `scripts/verify-pcap.sh`）
- **Review 门**：pcapng 字节级正确性 + Wireshark 互操作。

### 阶段 4：捕获层（NStat 绑定 + PKTAP helper + XPC）⚠️难点，重查证
> 进入前先用 context7/Apple 文档查证 `SMAppService`、`NSXPCConnection` 现代用法；以 XNU `bsd/net/ntstat.h` 与 `bsd/net/pktap.h` 真头文件为准定义结构。先写一个最小命令行 spike 验证 NStat 能拿到 (pid,5元组,bytes)、PKTAP 能拿到带 pid 的包，再正式实现。

- ⬜ **Task 4.0 NStat / PKTAP 可行性 spike（非 TDD，明确标注为探针，验证后删除或转正）**
  - **Files:** `Tools/nstat-spike/`（独立可执行）
  - [ ] dlopen NetworkStatistics，调 `NStatManagerCreate`/`NStatManagerAddAllTCP`/`AddAllUDP`/`NStatManagerSetInterfaceTrafficDescriptionBlock`，打印每连接 pid+5元组+字节，确认非 root 可用
  - [ ] open `/dev/bpf`，`BIOCSETIF` 绑定 `pktap`，`ioctl` 启用 pktap header，读若干包打印 pid/comm，确认需 root
  - [ ] 把验证到的真实符号签名/结构记录到 `docs/superpowers/notes/capture-spike.md`（中文内部）
- ⬜ **Task 4.1 MatrixNetXPC 协议契约**
  - **Files:** Create `Sources/MatrixNetXPC/CaptureXPC.swift`；加目标
  - **Interfaces Produces:** `@objc protocol CaptureControl`（`startCapture(interface:bpfFilter:reply:)`、`stopCapture`）；`@objc protocol CaptureEvents`（`didCapture(_ encoded: Data)`）；`struct CapturedPacketWire: Codable`（timestamp/dir/pid/origLen/data/iface）+ 编解码
  - [ ] 失败测试：`CapturedPacketWire` 编解码往返；非法/截断数据解码返回 nil 不崩溃
  - [ ] 实现 → PASS → commit
- ⬜ **Task 4.2 捕获抽象协议（可 mock）**
  - **Files:** Create `Sources/MatrixNetCapture/CaptureProtocols.swift`
  - **Interfaces Produces:** `protocol ConnectionMonitoring: Sendable { func start() async; var events: AsyncStream<ConnectionEvent> }`；`enum ConnectionEvent { case added(Connection); case counts(id:UUID,rx:UInt64,tx:UInt64); case removed(UUID) }`；`protocol PacketCapturing: Sendable { func start(filter:) async throws; var packets: AsyncStream<Packet> ; func stop() }`
  - [ ] 失败测试：提供 `MockConnectionMonitor`，喂事件序列驱动一个 `ConnectionAggregator`（用 FlowCorrelator）产出快照；断言聚合正确
  - [ ] 实现 `ConnectionAggregator`（actor，消费事件 → FlowCorrelator + IPv4-mapped 归一化）→ PASS → commit
- ⬜ **Task 4.3 NStat 绑定实现（私有框架，隔离）**
  - **Files:** Create `Sources/MatrixNetCapture/NetworkStatisticsMonitor.swift` + `NStatSymbols.swift`（dlopen/dlsym 解析）
  - [ ] 单元测试（可在 CI 跑）：符号解析失败时 `NetworkStatisticsMonitor` 降级（events 空、不崩溃）；结构解码用录制的字节做断言（不依赖真实内核）
  - [ ] 实现 dlopen + `NStatManager*` 高层符号（绝不手解 struct，读 description CFDictionary key）；映射为 `ConnectionEvent` → 手动机器验证
  - [ ] commit `feat(capture): NetworkStatistics monitor (isolated, dlopen)`
- ⬜ **Task 4.4 Helper daemon（PKTAP 抓取 + XPC 服务）**
  - **Files:** Create `Helper/Sources/main.swift`、`Helper/Sources/PKTAPCapture.swift`、`Helper/MatrixNetHelper.entitlements`
  - [ ] 单元测试：PKTAP header 解析（从录制字节提取 pid/comm/dir）；BPF 读循环的分帧逻辑（`BIOCGBLEN`/`bpf_hdr` 对齐）用录制缓冲测试
  - [ ] 实现 helper：`NSXPCListener`(MachService) + 校验调用方签名(Team ID + bundleid via `SecCode`/audit token) + 打开 bpf 绑 pktap + en0/utun* 双抓 + 推 `CapturedPacketWire` → 手动机器验证（需 root）
  - [ ] commit `feat(helper): privileged PKTAP capture over XPC`
- ⬜ **Task 4.5 SMAppService 注册 + 客户端**
  - **Files:** Create `Sources/MatrixNetCapture/HelperInstaller.swift`、`Sources/MatrixNetCapture/XPCPacketCapture.swift`
  - [ ] 查证 `SMAppService.daemon(plistName:)` 现代用法（context7/Apple 文档）
  - [ ] 单元测试：安装状态机（notRegistered/needsApproval/enabled）映射；XPC 断连重连降级
  - [ ] 实现注册 + XPC 客户端实现 `PacketCapturing` → 手动机器验证
  - [ ] commit
- **Review 门**：安全审查（helper 最小特权、调用方校验、不解析仅转发）+ 私有框架隔离 + 降级路径。

### 阶段 5：MatrixNetStore + GeoIP
- ⬜ **Task 5.1 GeoIP**
  - **Files:** Create `Sources/MatrixNetGeoIP/GeoIPDatabase.swift`；选 DB-IP/ip2location-lite（许可对开源友好，CC-BY 类）放 Resources
  - [ ] 失败测试：已知 IP → 国家码（用内置小型测试数据）；未知/私有 IP → nil；IPv6 支持；边界（0.0.0.0、广播、私网段标记）
  - [ ] 实现（二分查找 IP 区间表）→ PASS → commit
- ⬜ **Task 5.2 Store（SwiftData 历史 + pcap 文件 ring buffer）**
  - **Files:** Create `Sources/MatrixNetStore/ConnectionRecord.swift`（@Model）、`CaptureFileStore.swift`
  - [ ] 失败测试：`CaptureFileStore` 写入超过上限时按时间滚动删除最旧文件，保持总量 ≤ 上限；并发写安全
  - [ ] 实现 → PASS → commit（SwiftData 模型的 CRUD 用内存容器测试）
- **Review 门**：持久化正确性 + ring buffer 边界。

### 阶段 6：SwiftUI UI（精致简约，HIG/Liquid Glass）
> 进入前用 design 技能（frontend-design/ui-ux-pro-max）+ brainstorming 浏览器可视化伴侣产高保真 mockup 自评；查证 macOS 26 SwiftUI 新 API（context7/Apple）。
- ⬜ **Task 6.1 视图模型（可测试，无 UI）**
  - **Files:** Create `App/Sources/ViewModels/ConnectionListViewModel.swift`、`CaptureViewModel.swift`（`@Observable`/`@MainActor`）
  - [ ] 失败测试：注入 mock 捕获源 → viewModel 暴露排序/过滤后的连接列表；过滤表达式；速率计算（字节差/时间差）
  - [ ] 实现 → PASS → commit
- ⬜ **Task 6.2 显示过滤器 DSL（可测试）**
  - **Files:** Create `App/Sources/Filter/DisplayFilter.swift`
  - [ ] 失败测试：`ip.addr == 1.2.3.4 && tcp.port == 443` 解析 + 对 Packet/Connection 求值；语法错误报位置
  - [ ] 实现一个小型递归下降解析器 + 求值 → PASS → commit
- ⬜ **Task 6.3 界面骨架**：`NavigationSplitView`（概览/连接/抓包/历史/设置）、连接 `Table`+`Inspector`、抓包三栏（列表/树/hex）、菜单栏 `MenuBarExtra`、onboarding/权限引导。（UI 以预览 + 手动验证为主）
  - [ ] 每个视图建 `#Preview`，截图自评；commit 分视图提交
- ⬜ **Task 6.4 接线**：viewModel ↔ Capture/Store/GeoIP/Dissection；启动权限引导。
- **Review 门**：design 技能 mockup 自评 + code-review + 手动 HIG 走查。

### 阶段 7：构建 + 签名 + 公证 + 部署
- ⬜ **Task 7.1 project.yml + 构建**
  - **Files:** Create `project.yml`、`App/Info.plist`、entitlements、`Config/Base.xcconfig`
  - [ ] `xcodegen generate` → `xcodebuild -scheme MatrixNet build` 成功（无沙箱、Hardened Runtime）
  - [ ] helper 作为 `SMAppService` daemon 嵌入 `Contents/Library/LaunchDaemons/` + 可执行嵌入 + plist（查证布局）
- ⬜ **Task 7.2 签名 + 公证 + staple（脚本）**
  - **Files:** Create `scripts/build.sh`、`scripts/sign.sh`、`scripts/notarize.sh`、`scripts/make-dmg.sh`
  - [ ] codesign app + helper（Developer ID，`--options runtime`，helper 用受限 entitlements）
  - [ ] `notarytool submit --key AuthKey_F6M57PP394.p8 --key-id F6M57PP394`（Individual Key；若需 issuer 则补 store-credentials）→ `stapler staple`
  - [ ] `spctl -a -vvv` / `codesign --verify --deep --strict` 验证
- ⬜ **Task 7.3 部署本机**：安装到 `/Applications`，启动，走 onboarding，授权 helper（用户手动一次），验证连接监控 + 抓包 + pcapng 导出在真实环境工作；与 AdGuard/代理软件共存冒烟测试。
- **Verify 门**：真机端到端验证 + 与代理软件零冲突冒烟。

### 阶段 8：GitHub 仓库 + CI/CD
- ⬜ **Task 8.1 建仓库 + 推送**：`gh repo create MatrixReligio/MatrixNet --public`；推 main。
- ⬜ **Task 8.2 CI**（`.github/workflows/ci.yml`）：macOS-15/26 runner；`xcodegen generate`；`swift build`（warnings-as-errors）；`swiftlint --strict`；`swiftformat --lint`；`swift test`；独立 job `swift test --sanitize=thread`；覆盖率上报。
- ⬜ **Task 8.3 Release**（`release.yml`）：tag 触发；构建 + 签名 + 公证（secrets：API key/issuer base64）+ staple + 生成 .dmg + 创建 GitHub Release。
- ⬜ **Task 8.4 开源治理**：issue/PR 模板、`dependabot.yml`、`CODEOWNERS`、branch protection（要求 CI 通过）、badges 接线。
- **Review 门**：CI 全绿 + workflow 安全（secrets 不泄露、最小权限）+ 开源规范检查。

---

## Self-Review（计划对照 spec）

- **spec 覆盖**：①连接监控→阶段4.2/4.3+6；②深度抓包→阶段2+4.4；③按App归类→Model+4.2；④关联→FlowCorrelator+4.2；⑤pcapng→阶段3；⑥历史→5.2；⑦菜单栏/onboarding→6.3；⑧签名公证→7；⑨零冲突→4(无NE)；⑩开源规范→0/8；⑪测试(边界+并发+Swift Testing+TSan)→各阶段+8.2。地图列为 6 可选。无遗漏。
- **占位符扫描**：无 TBD/TODO 残留；难点（NStat/PKTAP/SMAppService）已标"先 spike + 查证"而非臆测。
- **类型一致性**：`ConnectionEvent`/`CapturedPacketWire`/`FlowCorrelator` 等契约在阶段间名称一致。
- **风险**：NStat 私有框架跨版本（隔离+回归）、PKTAP VPN 内外层归因（en0+utun*双抓+真机核对）、公证 issuer（必要时补）、helper 授权需用户手点（onboarding 引导）。
