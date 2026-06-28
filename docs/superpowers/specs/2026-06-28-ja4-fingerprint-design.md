# 功能 ① 设计:JA4 TLS 客户端指纹 × 按进程归属

> 本批(抓包/协议分析方向)第 1 个子项目。内部设计文档(中文)。
> 目标版本:**1.2.0(build 31)**(当前真源 1.1.0 / build 30,新功能 → MINOR)。

## 1. 目标与价值(一句话)

被动地从每条 TLS 连接的 **ClientHello** 计算 **JA4 客户端指纹**,并**按进程归属**——回答"**这个进程用的是什么 TLS 栈/库**"(Chrome 系 / Go / curl / Python / 未知 / 可疑模仿),竞品在 macOS 桌面端无人做 per-app JA4。这是被动协议智能的基础设施,后续 ②(QUIC 的 JA4 变体)、承载层(进程活动时间线)、未来安全包(恶意指纹情报)都建立其上。

## 2. 范围与边界(已据当前实现最优决策)

### 2.1 做什么(本版 MVP)
- 从 ClientHello 完整解析 JA4 所需字段并计算 **JA4 字符串**(`a_b_c` 三段式)。**本版只做 TCP-TLS(传输前缀 `t`)**;QUIC 变体(`q`)留给功能 ②,核心计算预留传输参数无缝复用。
- **客户端识别**:可扩展的"指纹→标签/类别"匹配机制 + **内置一批 license 干净的常见客户端种子**(Chromium/Firefox/Safari/curl/Go stdlib/Python-requests 等);未命中显示原始 JA4 + 解码摘要。
- **per-app 聚合**:把每条流观测到的 JA4 归属到进程,得到"每应用的 TLS 指纹集合"。
- **轻量持久化**:per-app 指纹(firstSeen/lastSeen/count)落库,跨重启可留存,为时间线铺路。
- **UI**:① 数据包检查器里 TLS 层节点新增 `JA4` 字段 + 人类可读解码;② 连接检查器里展示选中连接所属进程的已观测指纹与识别出的 TLS 栈;③ 未开抓包时给清晰的"启用抓包以查看 TLS 指纹"空态。
- **多语言(8 语言)+ 开源文档(README/CHANGELOG/DocC)** 随提交更新。

### 2.2 固有边界(非缩范围,是物理事实)
- **JA4 只能来自 PKTAP 原始包**:NStat 只有连接级元数据、无 payload,**无法**像用量那样回退 NStat。故 JA4 是"开启抓包(特权 helper)才有数据"的功能,与"数据包"页同源。设计以**优雅空态**处理未开抓包的情况,而非假装有数据。
- **ECH(Encrypted ClientHello)**:未来若服务端启用 ECH,inner ClientHello 加密,JA4 的 SNI 段退化为 `i`、区分度下降。当前采用率极低,设计**优雅降级**(照常计算可见部分),不为其特殊处理。

### 2.3 不做(本版明确排除,留后续)
- 不做 **JA4S/JA4H/JA4X/JA4T** 等衍生方法——它们受 FoxIO License 1.1 + patent-pending 约束,**不碰**(仅做 BSD-3、FoxIO 已放弃专利的 JA4 客户端指纹本体)。
- 不做 **JA3**——浏览器扩展乱序已使其对现代客户端失效。
- 不内置**恶意指纹情报源**(sslbl/ja4db);识别机制本版交付,恶意源作为后续"安全包"按 GeoIP/威胁库自更新模式再挂(与项目已有威胁库分离一致)。
- 不做证书审计、cipher 健康度告警(后者可作为 JA4 解析的附赠维度,本版不投入)。

## 3. 关键技术依据(已交叉验证)

- **JA4 构成**(FoxIO `ja4/technical_details/JA4.md`):
  - `JA4_a` = 传输(`t` TCP / `q` QUIC) + TLS 版本 2 位(取 `supported_versions` 扩展中最大值,去 GREASE;无则用 legacy `client_version`;1.3→`13`,1.2→`12`,1.1→`11`,1.0→`10`) + SNI 有无(有 `server_name` 扩展→`d`,无→`i`) + cipher 数(去 GREASE,2 位,≥99 记 `99`) + 扩展数(去 GREASE,**计数含 SNI 与 ALPN**,2 位) + 首个 ALPN 值的**首尾字符**(无 ALPN→`00`,如 `h2`→`h2`、`http/1.1`→`h1`)。
  - `JA4_b` = SHA256(**去 GREASE 后按升序排序**的 cipher 列表,4 位小写 hex,逗号连接)前 12 hex;无 cipher→`000000000000`。
  - `JA4_c` = SHA256( **去 GREASE 且剔除 SNI(0x0000)与 ALPN(0x0010)** 后按升序排序的扩展列表(逗号连接) + `_` + `signature_algorithms`(0x000d)按**原始顺序**(不排序)的 4 位 hex 逗号连接 )前 12 hex;无扩展→`000000000000`。
  - 规范示例(测试基准向量):`t13d1516h2_8daaf6152771_e5627efa2ab1`。
- **GREASE 判定**:值 `v` 满足 高低字节相等 且 低半字节为 `0xa`(即 `(v & 0x0f0f) == 0x0a0a && (v >> 8) == (v & 0xff)`),如 `0x0a0a,0x1a1a,…,0xfafa`。GREASE 出现在 cipher/扩展/supported_versions/sig_algs/ALPN,均需剔除。
- **许可**:JA4 本体 = BSD-3,FoxIO 明确声明不主张/不申请专利 → 可自由实现并 Apache-2.0 开源。NOTICE 注明算法出处。
- **SHA256**:用系统 `CryptoKit`(macOS 自带、确定性,可对 FoxIO 向量回归)。

## 4. 架构与组件(各单元单一职责、可独立测试)

数据流(全部在抓包开启时):
```
PKTAP helper → XPC didCapture → PacketDissector.dissect(bytes)
   → TLSDissector 解析 ClientHello → JA4ClientHello(字段) → JA4.string(transport:.tcp)
   → DissectedPacket.tlsClientFingerprint
PacketCaptureModel.attribute(rows) → ConnectionAggregator 记录 (flow/pid → JA4)
   → fingerprintSnapshot() → AppModel.flushFingerprints(节流) → FingerprintStore(SwiftData)
UI:Packets 检查器(TLS 节点 JA4 字段) + 连接检查器(per-app 指纹 + 识别标签)
```

### 4.1 纯协议核心(MatrixNetDissection,可 `swift test` 独立验证 —— 即第 0 阶段 spike 的对象)
- **`JA4ClientHello`**(新):从 ClientHello 解析出的中间表示——`tlsVersion`、`ciphers:[UInt16]`、`extensions:[UInt16]`、`signatureAlgorithms:[UInt16]`、`alpnFirst:String?`、`hasSNI:Bool`。纯结构,GREASE 未剔除(剔除在计算层做,便于分别测试)。
- **`JA4`**(新):`enum Transport{ case tcp, quic }`;`static func string(from: JA4ClientHello, transport:) -> String`。内部:`partA`、`partB`、`partC` 三个**纯**子函数(可分别 TDD),`partB/partC` 用 CryptoKit SHA256。提供 `rawB/rawC`(哈希前字符串)便于断言中间结果。
- **`JA4Identifier`**(新):`static func identify(_ ja4: String) -> JA4Label?`,匹配内置种子表(`{ja4 或 a 段前缀 → label, category}`)。纯、可 TDD。表结构便于后续从数据集加载(GeoIP/威胁库模式),本版为内置种子。
- **`TLSDissector` 扩展**:`parseClientHello` 从"只取 SNI"扩展为同时产出 `JA4ClientHello`;`Result` 增 `clientFingerprint: String?` 与 `clientFingerprintLabel: JA4Label?`;TLS 节点 `fields` 增 `JA4` 与可选 `Client` 行。保持"任何畸形输入 best-effort、不抛"。

### 4.2 归属与快照(MatrixNetModel / MatrixNetCapture)
- **`DissectedPacket`** 增 `tlsClientFingerprint: String?`(沿 hostnames 同样路径透出)。
- **`ConnectionAggregator`** 增 `fingerprintsByFlow`(flow→JA4,后写覆盖即可,客户端栈稳定)与 per-app 归并;`fingerprintSnapshot() -> [AppFingerprintObservation{app, ja4, label?}]`。记录入口与 `recordHostname` 对称(`recordFingerprint`)。
- **`AppFingerprintObservation`**(新,纯,MatrixNetModel):`app, ja4, label?, transport`。

### 4.3 持久化(MatrixNetStore,复用单一 SharedModelContainer)
- **`AppFingerprintRecord`**(新 @Model):`app, ja4, label?, transport, firstSeen, lastSeen, count`。**加入 `SharedModelContainer.schema`**(第 4 个模型,additive schema,低风险;严禁单独开容器——多容器会丢表)。
- **`FingerprintStore`**(新,`init(container:)` 注入共享容器;`inMemory()` 供测试):`record(app, ja4, label, transport, at:)` 按 (app, ja4) 去重 upsert(更新 lastSeen、count++);`load() -> [String: [StoredFingerprint]]` 按 app 归并。
- **AppModel** 启动用 `SharedModelContainer.make()` 构造 `FingerprintStore`;`flushFingerprints()` 节流(≥30s,同 flushUsage)把 `fingerprintSnapshot()` upsert 入库。

### 4.4 UI(App/Sources)
- **Packets 检查器**:TLS 层节点已显示 `fields`,新增的 `JA4`/`Client` 字段自动出现,**零新视图**。
- **连接检查器**:选中连接 → 显示该连接 JA4 + 该**进程**已观测指纹集合与识别标签;无指纹(未抓包或非 TLS)时显示引导/占位。
- **空态**:抓包未开时,指纹区显示"启用抓包(设置 → 抓包)以查看 TLS 指纹",与 Packets 页一致。

## 5. 错误处理与降级
- ClientHello 截断/畸形:`TLSDissector` 既有 `try?`/`ByteReader` 边界检查,任何字段缺失 → `clientFingerprint = nil`,不影响其余层与 SNI。
- 非 ClientHello(ServerHello/ApplicationData):不产生客户端指纹(JA4 是客户端侧)。
- 抓包未开:无包 → 无指纹 → UI 空态引导(非错误)。
- CryptoKit 不可用场景:不存在(macOS 系统框架);测试用确定性向量。

## 6. 测试策略(TDD)

### 6.1 第 0 阶段:协议核心 spike(纯模块,`swift test`,不动 app、不发版)
**目的:先验证 JA4 计算技术符合预期,把风险隔离在 app 之外**(响应"先做小 demo 验证")。
- `JA4` 对 **FoxIO 规范向量** 回归:给定规范 ClientHello 字段 → 断言输出 `t13d1516h2_8daaf6152771_e5627efa2ab1`(含 `rawB/rawC` 中间串断言)。
- GREASE 剔除、cipher/扩展升序、计数 cap 99、SNI `d`/`i`、ALPN 首尾(`h2`/`http/1.1`→`h1`/无→`00`)、版本取 `supported_versions` 最大值、JA4_c 剔除 SNI+ALPN 且 sig_algs 不排序——逐项单测。
- `JA4ClientHello` 解析:从**真实 ClientHello 字节**(hex 夹具,含 GREASE/supported_versions/ALPN)解析字段正确;畸形/截断 → 安全返回 nil。
- **真实字节验证(best-effort)**:用 `openssl s_client -msg` 或一次本地抓包取一条真实 ClientHello,喂入计算并与参考(Wireshark JA4 插件 / `ja4` 工具,若可得)比对;结果与配方写入 `docs/superpowers/notes/ja4-spike.md`(同 capture-spike.md 体例)。若网络/工具不可得,FoxIO 向量为权威基准、足以验证。
- `JA4Identifier`:命中种子→标签,未命中→nil。

### 6.2 接入阶段(影响 app 版本,spike 绿后才进行)
- `TLSDissector`:ClientHello → `clientFingerprint` 非空且等于核心计算;ServerHello/非 TLS → nil;SNI 仍正确(回归)。
- `ConnectionAggregator`:`recordFingerprint` → `fingerprintSnapshot` 按 app 归并、去重;flow→app 正确。
- `FingerprintStore`:upsert 去重(同 app+ja4 不重复插入、count 递增、lastSeen 更新);load 归并;加入 SharedModelContainer 后**三旧模型表仍在**(多容器回归)。
- 全程 Swift Testing;零警告;swiftlint --strict + swiftformat 全清;8 语言本地化校验过。

## 7. 交付与发版
- 第 0 阶段 spike 绿 + notes 记录 → review。
- 接入阶段实现 → code-reviewer 门、清零问题 → 测试全绿 → 文档(README 8 语言 bullet、CHANGELOG、DocC、NOTICE 加 JA4/FoxIO 署名)→ 版本号真源改 `project.yml` 两处 info.properties 为 `1.2.0`/`31`(+ 同步 settings.base)→ `xcodegen generate` 校验 → 提交(**无 Claude 署名**)→ push → `gh workflow run Release -f version=v1.2.0` → 验证 appcast(sparkle:version=31)→ 本地 Developer-ID 安装。

## 8. 自审清单(本节实现前自检)
- 无 TBD/占位符;范围聚焦单一可实现计划。
- 一致性:JA4 计算位置(MatrixNetDissection)/持久化(SharedModelContainer 加模型)/UI(复用既有检查器)前后一致。
- 命名一致:`JA4ClientHello`/`JA4`/`JA4Identifier`/`AppFingerprintObservation`/`AppFingerprintRecord`/`FingerprintStore`/`recordFingerprint`/`fingerprintSnapshot`/`flushFingerprints` 全文统一。
- 歧义消除:JA4_a 扩展计数含 SNI+ALPN,但 JA4_c 哈希列表剔除二者——已显式写明。
