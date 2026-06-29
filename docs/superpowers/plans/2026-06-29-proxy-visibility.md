# 代理真实可见性(Proxy-Aware True Destination & Bytes)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (推荐)或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 在 TUN 模式本地代理(Loon/Surge-legacy/Clash,含 fake-IP)下,把经代理连接的真实**域名 + 上/下字节 + 发起 app** 还原出来,并诚实处理地理位置。

**Architecture:** 复用已无过滤捕获 utun/lo0/en0 的 PKTAP 流;新增纯核心单元(`FakeIPClassifier` + `TunneledFlowReconstructor`)把 utun 出向包还原成"真实 app→真实域名"的流,按包长累加真实字节;修复 `ConnectionAggregator` 把 NStat 的 0 字节代理连接缝回包级数据;`OverviewStats.proxyShare` 改按字节;fake-IP 不喂 GeoIP;新增默认开、仅对"代理流+geo 未知"触发的主动解析器。

**Tech Stack:** Swift 6(strict concurrency)、Swift Testing、SwiftPM 纯核心包、SwiftUI(设置 UI)、Sparkle(发版)。

> **⚠️ 2026-06-29 纠偏(已验证,覆盖下方部分原计划)**:lsof 证实 NStat 给代理连接报的 5-tuple 与 utun 包一致(都用网关 `198.19.0.1`);`Tests/MatrixNetCaptureTests/ConnectionAggregatorProxyTests.swift` 证实**现有 flowKey 管线在抓包开启时本就恢复代理连接真实字节,`recordHostname` 也已挂上 SNI 域名**。因此:
> - Phase 0 的 `TunneledFlowReconstructor`/`TunneledFlowStitch` **已删除(冗余,commit 7c7645d)**;保留 `FakeIPClassifier` + 特征化测试。
> - **"进代理流量 0" 根因 = 未开包捕获(NStat-only)**——物理限制(无包即无字节,任何被动手段都变不出)。
> - **真正剩余工作**:① fake-IP geo 守卫(Task 1.4)② proxyShare 按字节(1.3)③ en0 relay 去重(1.2)④ 可选 DoH geo(Phase 2,已验证可行)⑤ **新增** NStat-only 诚实 UX:代理流标"需开启包捕获才能统计流量",替代误导性的 0。
> - 下方 **Task 1.1(接 reconstructor)作废**,由 ⑤ + "抓包模式下 geo 用域名而非 fake-IP" 取代。Task 1.2/1.3/1.4、Phase 2/3 仍有效。

## Global Constraints(逐条来自 spec / 项目约定,精确值)

- 目标版本 **1.8.0**(MINOR),build 39;版本真源 = `project.yml` 两处 `info.properties` + `settings.base`(MARKETING_VERSION/CURRENT_PROJECT_VERSION)。
- **100% 被动抓包不变**;主动解析**默认开**但**仅对"用代理 + geo 未知"触发** → 非代理用户仍纯被动。
- 主动解析必须:**仅用 DoH(IP 字面量端点,如 https://1.1.1.1/dns-query)**——明文 DNS/UDP 会被 TUN 劫持成 fake IP,不可用;**先 demo 验证可行再做(Task 2.0),不可行即放弃 Phase 2 并汇报**。须**限流+缓存**、**把自身解析查询排除出抓包统计**、首启告知、可一键关。
- 公开文案(用户拍板"仅代理场景说明"):README/隐私页**保留被动招牌**,仅加一句"使用本地代理时,GeoIP 解析默认会发起 DNS 查询以补全国家,可在设置关闭";badge 不动。8 语言串。
- 诚实限制写进文档:经远程节点的真服务器 IP/geo 被动不可得;Surge 5.8+ 纯 NE 隧道未验证→降级标注;ECH 时域名未知。
- Swift 6 strict concurrency;`swiftlint --strict` + `swiftformat --lint` 零告警;TDD;Conventional Commits;**提交不带 Claude 署名**(`git -c user.name="Jim Ho" -c user.email="jim.ho@matrixreligio.com"`)。
- 开源代码/DocC = 英文;spec/plan/沟通 = 中文。
- 每阶段 review 前**全量回归**(测试 + bundle 数据集真的打进去)。
- **每阶段不向用户逐一确认**(用户偏好自主连续推进)。

## 单元与文件职责(决策锁定)

| 文件 | 职责 | 类型 |
|---|---|---|
| `Sources/MatrixNetModel/FakeIPClassifier.swift`(新) | 判定 dst 是否为合成 fake-IP(保留段 + 学习到的代理池/有域名映射的地址) | 纯函数,Phase 0 |
| `Sources/MatrixNetModel/TunneledFlowReconstructor.swift`(新) | 把 utun 出向包流还原为 `(app PID, 真实 5-tuple/域名, 字节)` | 纯函数,Phase 0 |
| `Sources/MatrixNetCapture/ConnectionAggregator.swift`(改) | 缝合 NStat 0 字节代理连接 ↔ 包级数据;en0 relay 去重 | actor,Phase 1 |
| `Sources/MatrixNetModel/OverviewStats.swift`(改) | `proxyShare` 改按字节 | 纯函数,Phase 1 |
| GeoIP 消费端(`OverviewStats`/Map/Connections 富化处) | fake-IP 跳过 GeoIP | Phase 1 |
| `Sources/MatrixNetGeoIP/`(新 `ActiveGeoResolver.swift`) | 默认开、仅代理+未知 geo 触发的专用解析器(协议+实现) | Phase 2 |
| `App/Sources/...Settings` + 本地化串 | 解析开关 + 隐私文案 + 8 语言 | Phase 2 |
| `README*.md`/`CHANGELOG.md`/`NOTICE`/DocC | 文档同步 | Phase 3 |

---

## Phase 0 — 纯核心 spike(`swift test` 可独立跑,不动 app,不发版)

> 用 spec §2 真机数据做向量:出向 `proc=Safari/Claude/curl` 的 utun 包、网关 src `198.19.0.1`、fake dst `198.0.0.60`、携 SNI 的 ClientHello;en0 上 `LoonTunnelProvider` 到真实 IP。绿 + code-reviewer 通过后才进 Phase 1。

### Task 0.1: FakeIPClassifier — 保留合成段判定

**Files:**
- Create: `Sources/MatrixNetModel/FakeIPClassifier.swift`
- Test: `Tests/MatrixNetModelTests/FakeIPClassifierTests.swift`

**Interfaces:**
- Consumes: `IPAddress`(`.v4(UInt32)`、`.unmappedIPv4`)。
- Produces: `struct FakeIPClassifier: Sendable { init(learnedSyntheticPrefixes16: Set<UInt32>); func isSynthetic(_ ip: IPAddress) -> Bool; static func isReservedSyntheticV4(_ ip: IPAddress) -> Bool }`。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import MatrixNetModel

@Suite struct FakeIPClassifierTests {
    @Test func reservedBenchmarkRangeIsSynthetic() {
        // 198.18.0.0/15 (RFC 2544) — Loon/Surge/Clash 默认网关与池常用
        #expect(FakeIPClassifier.isReservedSyntheticV4(IPAddress("198.19.0.1")!))
        #expect(FakeIPClassifier.isReservedSyntheticV4(IPAddress("198.18.0.0")!))
        #expect(FakeIPClassifier.isReservedSyntheticV4(IPAddress("198.19.255.255")!))
    }
    @Test func cgnatAndReservedAreSynthetic() {
        #expect(FakeIPClassifier.isReservedSyntheticV4(IPAddress("100.64.0.1")!))   // 100.64/10
        #expect(FakeIPClassifier.isReservedSyntheticV4(IPAddress("240.0.0.1")!))    // 240/4
    }
    @Test func realPublicIsNotSynthetic() {
        #expect(!FakeIPClassifier.isReservedSyntheticV4(IPAddress("8.8.8.8")!))
        #expect(!FakeIPClassifier.isReservedSyntheticV4(IPAddress("101.226.100.232")!)) // 真机 en0 真实 IP
    }
    @Test func learnedProxyPoolIsSynthetic() {
        // 真机观察到的 fake 池 198.0.x.x 不在保留段,靠学习到的 /16 前缀命中
        let prefix16 = UInt32(0xC600_0000) >> 16 // 198.0.0.0/16
        let sut = FakeIPClassifier(learnedSyntheticPrefixes16: [prefix16])
        #expect(sut.isSynthetic(IPAddress("198.0.0.60")!))
        #expect(!sut.isSynthetic(IPAddress("8.8.8.8")!))
    }
}
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter FakeIPClassifierTests`,期望 `cannot find 'FakeIPClassifier'`。
- [ ] **Step 3: 最小实现**

```swift
/// Classifies whether a destination is a synthetic fake-IP handle minted by a
/// TUN proxy (Clash/Loon/Surge) rather than a routable address. Such addresses
/// must NOT be geolocated; the real destination comes from SNI/DNS instead.
public struct FakeIPClassifier: Sendable {
    /// /16 prefixes (high 16 bits of the IPv4 value) learned at runtime as a
    /// proxy fake-IP pool (e.g. from the tunnel gateway / proxy-DNS answers),
    /// for pools that fall outside the reserved ranges below.
    private let learnedSyntheticPrefixes16: Set<UInt32>

    public init(learnedSyntheticPrefixes16: Set<UInt32> = []) {
        self.learnedSyntheticPrefixes16 = learnedSyntheticPrefixes16
    }

    public func isSynthetic(_ ip: IPAddress) -> Bool {
        if Self.isReservedSyntheticV4(ip) { return true }
        guard case let .v4(value) = ip.unmappedIPv4 else { return false }
        return learnedSyntheticPrefixes16.contains(value >> 16)
    }

    /// Reserved/benchmarking ranges TUN proxies carve fake-IP pools and gateways
    /// from. Real internet traffic never uses these.
    public static func isReservedSyntheticV4(_ ip: IPAddress) -> Bool {
        guard case let .v4(value) = ip.unmappedIPv4 else { return false }
        if value & 0xFFFE_0000 == 0xC612_0000 { return true } // 198.18.0.0/15
        if value & 0xFFC0_0000 == 0x6440_0000 { return true } // 100.64.0.0/10
        if value & 0xF000_0000 == 0xF000_0000 { return true } // 240.0.0.0/4
        return false
    }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter FakeIPClassifierTests` 全绿。
- [ ] **Step 5: lint + commit** — `swiftformat Sources/MatrixNetModel/FakeIPClassifier.swift Tests/MatrixNetModelTests/FakeIPClassifierTests.swift && swiftlint --strict`;`git -c user.name="Jim Ho" -c user.email="jim.ho@matrixreligio.com" commit -m "feat(proxy): classify synthetic fake-IP destinations"`。

### Task 0.2: TunneledFlowReconstructor — utun 出向流 → (app, 域名, 字节)

**Files:**
- Create: `Sources/MatrixNetModel/TunneledFlowReconstructor.swift`
- Test: `Tests/MatrixNetModelTests/TunneledFlowReconstructorTests.swift`

**Interfaces:**
- Consumes: `FiveTuple`、`FlowKey`、`IPAddress`。一个**已抽象的输入**(不依赖 PKTAP 解析细节):`struct TunneledPacket { let onTunnel: Bool; let pid: Int32; let outbound: Bool; let fiveTuple: FiveTuple; let payloadLength: Int; let sni: String? }`。
- Produces: `struct TunneledFlowReconstructor`,`mutating func ingest(_ p: TunneledPacket)`;`func flows() -> [ReconstructedFlow]`。`struct ReconstructedFlow: Sendable, Equatable { let flowKey: FlowKey; let pid: Int32; let domain: String?; let fakeDestination: Endpoint; var bytesOut: UInt64; var bytesIn: UInt64 }`。

- [ ] **Step 1: 写失败测试**(用真机向量)

```swift
import Testing
import MatrixNetModel

@Suite struct TunneledFlowReconstructorTests {
    // 真机: utun 出向 proc=Safari, src 网关 198.19.0.1:52750 -> fake 198.0.0.60:443
    private func tuple(_ srcPort: UInt16, _ dst: String, _ dstPort: UInt16 = 443) -> FiveTuple {
        FiveTuple(proto: .tcp,
                  source: Endpoint(address: IPAddress("198.19.0.1")!, port: srcPort),
                  destination: Endpoint(address: IPAddress(dst)!, port: dstPort))
    }

    @Test func reconstructsAppDomainAndBytesFromTunnelOutbound() {
        var sut = TunneledFlowReconstructor()
        let ft = tuple(52750, "198.0.0.60")
        // ClientHello 出向带 SNI
        sut.ingest(.init(onTunnel: true, pid: 1778, outbound: true, fiveTuple: ft,
                         payloadLength: 517, sni: "www.cloudflare.com"))
        // 入向回包(由代理写回,pid 可能不同),按 flowKey 归同一流并累加
        sut.ingest(.init(onTunnel: true, pid: 14428, outbound: false,
                         fiveTuple: FiveTuple(proto: .tcp, source: ft.destination, destination: ft.source),
                         payloadLength: 1400, sni: nil))
        let flows = sut.flows()
        #expect(flows.count == 1)
        let f = try! #require(flows.first)
        #expect(f.pid == 1778)                       // 取出向腿的真实 app PID
        #expect(f.domain == "www.cloudflare.com")    // 取出向 SNI
        #expect(f.fakeDestination.address == IPAddress("198.0.0.60")!)
        #expect(f.bytesOut == 517)
        #expect(f.bytesIn == 1400)
    }

    @Test func ignoresNonTunnelPackets() {
        var sut = TunneledFlowReconstructor()
        sut.ingest(.init(onTunnel: false, pid: 14428, outbound: true,
                         fiveTuple: tuple(50002, "101.226.100.232"), payloadLength: 1200, sni: nil))
        #expect(sut.flows().isEmpty) // en0 上代理上游腿不归本 reconstructor
    }

    @Test func keepsAppPidFromOutboundEvenIfInboundSeenFirst() {
        var sut = TunneledFlowReconstructor()
        let ft = tuple(49956, "198.0.0.16")
        sut.ingest(.init(onTunnel: true, pid: 14428, outbound: false,
                         fiveTuple: FiveTuple(proto: .tcp, source: ft.destination, destination: ft.source),
                         payloadLength: 60, sni: nil))
        sut.ingest(.init(onTunnel: true, pid: 24179, outbound: true, fiveTuple: ft,
                         payloadLength: 200, sni: "api.anthropic.com"))
        let f = try! #require(sut.flows().first)
        #expect(f.pid == 24179)               // 出向腿 PID 覆盖入向腿 PID
        #expect(f.domain == "api.anthropic.com")
    }
}
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter TunneledFlowReconstructorTests`,期望类型缺失。
- [ ] **Step 3: 最小实现**

```swift
/// Reconstructs the originating app, true domain (SNI), and true byte volume of
/// flows that a TUN proxy routes through a tunnel interface. The outbound leg
/// (app → tunnel) carries the real app PID and the cleartext SNI; the inbound
/// leg (written back by the proxy) is matched by direction-insensitive flow key
/// so both directions accumulate into one flow. Non-tunnel packets are ignored
/// here (they belong to the proxy's upstream relay on the physical interface).
public struct TunneledFlowReconstructor: Sendable {
    public struct TunneledPacket: Sendable {
        public let onTunnel: Bool
        public let pid: Int32
        public let outbound: Bool
        public let fiveTuple: FiveTuple
        public let payloadLength: Int
        public let sni: String?
        public init(onTunnel: Bool, pid: Int32, outbound: Bool,
                    fiveTuple: FiveTuple, payloadLength: Int, sni: String?) {
            self.onTunnel = onTunnel; self.pid = pid; self.outbound = outbound
            self.fiveTuple = fiveTuple; self.payloadLength = payloadLength; self.sni = sni
        }
    }

    public struct ReconstructedFlow: Sendable, Equatable {
        public let flowKey: FlowKey
        public var pid: Int32
        public var domain: String?
        public var fakeDestination: Endpoint
        public var bytesOut: UInt64
        public var bytesIn: UInt64
    }

    private var flowsByKey: [FlowKey: ReconstructedFlow] = [:]

    public init() {}

    public mutating func ingest(_ p: TunneledPacket) {
        guard p.onTunnel else { return }
        let key = p.fiveTuple.flowKey
        let bytes = UInt64(max(0, p.payloadLength))
        if var flow = flowsByKey[key] {
            if p.outbound {
                flow.bytesOut &+= bytes
                flow.pid = p.pid                       // outbound = authoritative app
                if let sni = p.sni { flow.domain = sni }
                flow.fakeDestination = p.fiveTuple.destination
            } else {
                flow.bytesIn &+= bytes
            }
            flowsByKey[key] = flow
        } else {
            flowsByKey[key] = ReconstructedFlow(
                flowKey: key,
                pid: p.pid,
                domain: p.outbound ? p.sni : nil,
                fakeDestination: p.outbound ? p.fiveTuple.destination : p.fiveTuple.source,
                bytesOut: p.outbound ? bytes : 0,
                bytesIn: p.outbound ? 0 : bytes
            )
        }
    }

    public func flows() -> [ReconstructedFlow] { Array(flowsByKey.values) }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter TunneledFlowReconstructorTests` 全绿。
- [ ] **Step 5: lint + commit** — 同 0.1 风格,`-m "feat(proxy): reconstruct tunneled flows to app+domain+bytes"`。

### Task 0.3: 缝合规则 — 把 NStat 0 字节连接对到重建流

**Files:**
- Create: `Sources/MatrixNetModel/TunneledFlowStitch.swift`
- Test: `Tests/MatrixNetModelTests/TunneledFlowStitchTests.swift`

**Interfaces:**
- Consumes: `Connection`、`TunneledFlowReconstructor.ReconstructedFlow`。
- Produces: `enum TunneledFlowStitch { static func merge(connection: Connection, flow: ReconstructedFlow) -> Connection; static func matches(connection: Connection, flow: ReconstructedFlow) -> Bool }`。匹配键 = **同 flowKey**(方向无关;若真机证明 NStat 报的是 app 真实本地址而非网关,Phase 1 改为按 `(app PID + fake dst)`,见 1.0)。合并:`bytesIn/out` 用流的真实值、`remoteHostname` 用 `flow.domain`。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import MatrixNetModel

@Suite struct TunneledFlowStitchTests {
    private func conn(_ srcPort: UInt16, _ dst: String) -> Connection {
        Connection(fiveTuple: FiveTuple(proto: .tcp,
            source: Endpoint(address: IPAddress("198.19.0.1")!, port: srcPort),
            destination: Endpoint(address: IPAddress(dst)!, port: 443)),
            app: AppIdentity(pid: 1778, displayName: "Safari"),
            bytesOut: 0, bytesIn: 0, startedAt: .init(timeIntervalSince1970: 0))
    }
    private func flow(_ srcPort: UInt16, _ dst: String) -> TunneledFlowReconstructor.ReconstructedFlow {
        let ft = FiveTuple(proto: .tcp,
            source: Endpoint(address: IPAddress("198.19.0.1")!, port: srcPort),
            destination: Endpoint(address: IPAddress(dst)!, port: 443))
        return .init(flowKey: ft.flowKey, pid: 1778, domain: "www.cloudflare.com",
                     fakeDestination: ft.destination, bytesOut: 517, bytesIn: 1400)
    }

    @Test func mergesRealBytesAndDomainOntoZeroByteConnection() {
        let merged = TunneledFlowStitch.merge(connection: conn(52750, "198.0.0.60"),
                                              flow: flow(52750, "198.0.0.60"))
        #expect(merged.bytesOut == 517)
        #expect(merged.bytesIn == 1400)
        #expect(merged.remoteHostname == "www.cloudflare.com")
    }
    @Test func matchesByFlowKey() {
        #expect(TunneledFlowStitch.matches(connection: conn(52750, "198.0.0.60"),
                                           flow: flow(52750, "198.0.0.60")))
        #expect(!TunneledFlowStitch.matches(connection: conn(52750, "198.0.0.60"),
                                            flow: flow(99999, "198.0.0.60")))
    }
}
```
> 注:`AppIdentity(pid:displayName:)` 的精确签名以 `Sources/MatrixNetModel/AppIdentity.swift` 为准,实现时核对(若需更多必填字段,补上)。

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 最小实现**

```swift
/// Stitches a kernel (NetworkStatistics) connection — which under a TUN proxy
/// reports a synthetic fake-IP destination and 0 bytes — to its reconstructed
/// tunneled flow, replacing the byte counters with the real packet-derived
/// totals and the hostname with the real SNI domain.
public enum TunneledFlowStitch {
    public static func matches(
        connection: Connection,
        flow: TunneledFlowReconstructor.ReconstructedFlow
    ) -> Bool {
        connection.fiveTuple.flowKey == flow.flowKey
    }

    public static func merge(
        connection: Connection,
        flow: TunneledFlowReconstructor.ReconstructedFlow
    ) -> Connection {
        var merged = connection
        merged.bytesOut = flow.bytesOut
        merged.bytesIn = flow.bytesIn
        if let domain = flow.domain { merged.remoteHostname = domain }
        return merged
    }
}
```

- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: 全量纯核心回归 + lint + commit** — `swift test`(全套绿)、`swiftformat --lint Sources Tests`、`swiftlint --strict`;`-m "feat(proxy): stitch zero-byte NStat connection to reconstructed flow"`。

### Task 0.4: code-reviewer gate(Phase 0)

- [ ] dispatch `feature-dev:code-reviewer` 审 0.1–0.3 的 diff;关注:fake-IP 误判风险、flowKey 缝合正确性、出向 PID 取舍、整型溢出/掩码。红则修绿再继续。

---

## Phase 1 — 接入 app(缝合键修复 + 按字节 proxyShare + fake-IP GeoIP 守卫 + en0 去重)

### Task 1.0: 缝合键校核 ✅ 已完成(2026-06-29,lsof 非 sudo)

实测:所有代理连接的 socket 本地址 = TUN 网关 `198.19.0.1`(如 `198.19.0.1:49224->198.0.0.70:443`),与 utun 包 src 一致。`lsof` 与 NStat 同源(内核 socket 信息),故 **NStat 连接 5-tuple == utun 包 5-tuple → flowKey 缝合成立,无需改键。**

**新增前置(Task 1.0b,先于 1.1):核实"抓包开启时现有 attributePackets 是否已归并 utun 字节"。** 既然 flowKey 一致,现有按 flowKey 的关联可能已处理字节 → 那 Phase 1 重心应是 **域名(SNI 替换 fake-IP 展示)+ fake-IP geo 守卫 + 按字节 proxyShare + en0 去重**,而非重复造字节归并。
- [ ] 读 `PacketCaptureModel.swift` 的 packet→`PacketAttribution` 路径:确认 utun(DLT=rawIP)包是否被送进 `attributePackets`、其 flowKey 是否正确、SNI 是否已被提取并 `recordHostname`。
- [ ] 据真实现状改写下方 1.1 的具体改动(可能从"造缝合"缩成"补域名+守卫"),避免冗余。

### Task 1.1: 捕获管线产出 onTunnel/outbound/sni,喂给 reconstructor

**Files:**
- Modify: `Sources/MatrixNetCapture/PacketCaptureModel.swift`(DLT→接口类型已有:`12=rawIP=utun`);把每包的 `onTunnel`(来自 DLT=rawIP 或接口名 utun*)、`outbound`(PKTAP `dir`/`pth_flags`)、`sni`(已有 TLS dissector)汇成 `TunneledFlowReconstructor.TunneledPacket`。
- Modify: `Sources/MatrixNetCapture/ConnectionAggregator.swift`:新增 `private var tunneledFlows = TunneledFlowReconstructor()`;新增 `func ingestTunneled(_ p: TunneledFlowReconstructor.TunneledPacket)`;在 `snapshot()` 里对 fake-IP/隧道连接走缝合。
- Test: `Tests/MatrixNetCaptureTests/ConnectionAggregatorProxyTests.swift`

**Interfaces:**
- Consumes: Phase 0 三个单元。
- Produces: `ConnectionAggregator.snapshot()` 对代理连接返回真实 bytes + domain。

- [ ] **Step 1: 写失败测试**(actor 级:喂入一条 0 字节 fake-IP 连接 + 对应隧道包,断言 snapshot 的该连接 bytes/hostname 为真实值)。完整测试代码按 `attributePackets` 既有测试风格写(`await aggregator.apply(.added(conn))`、`await aggregator.ingestTunneled(...)`、`let snap = await aggregator.snapshot()`)。
- [ ] **Step 2: 跑确认失败**。
- [ ] **Step 3: 实现** `ingestTunneled` 累加进 `tunneledFlows`;改 `snapshot()`:对每条连接,若 `packetBytesByConn` 命中则用之(现状),否则若存在 `matches` 的重建流 → `TunneledFlowStitch.merge`。把重建流的 per-app 字节也并入 `packetTrafficByApp`/`usageByFlow`(键 = 真实域名而非 fake IP)。
- [ ] **Step 4: 跑确认通过 + 不回归** `swift test`。
- [ ] **Step 5: commit** `-m "feat(proxy): surface true bytes+domain for tunneled connections"`。

### Task 1.2: en0 relay 去重(代理上游腿不计入 per-app)

**Files:**
- Modify: `Sources/MatrixNetCapture/ConnectionAggregator.swift`(`attributePackets`/会话累计处)。
- Test: 追加到 `ConnectionAggregatorProxyTests.swift`。

- [ ] **Step 1: 写失败测试** — 喂入 `TunnelProcess.isTunnel("LoonTunnelProvider")==true` 的 en0 连接字节,断言其**不**进 per-app 总量(`appTraffic()` 不含 LoonTunnelProvider 的中继量),避免与 utun 侧双算。
- [ ] **Step 2–4:** 实现:`accumulateSession`/`attributePackets` 中,当 `TunnelProcess.isTunnel(app.displayName)` 且该连接 dst 非 fake-IP(即 en0 上游腿)时,标记 relay、跳过 per-app 累加(仍可单列"代理上游"视图)。跑绿。
- [ ] **Step 5: commit** `-m "fix(proxy): exclude proxy upstream relay leg from per-app totals"`。

### Task 1.3: proxyShare 改按字节

**Files:**
- Modify: `Sources/MatrixNetModel/OverviewStats.swift:58-68`(`proxyShare()`)。
- Test: `Tests/MatrixNetModelTests/OverviewStatsTests.swift`(追加)。

- [ ] **Step 1: 写失败测试** — 给定若干连接(部分经代理、含真实字节),断言 `proxyShare` = 代理字节 / 总字节(而非连接数比)。
- [ ] **Step 2–4:** 把 `proxyShare` 入参/实现从计数改为按 `totalBytes` 加权(代理判定复用 `ProxyDetector.routesThroughProxyOrTunnel` + fake-IP/`TunnelProcess`)。跑绿,更新受影响的既有测试。
- [ ] **Step 5: commit** `-m "feat(overview): compute proxy share by bytes"`。

### Task 1.4: fake-IP 不喂 GeoIP

**Files:**
- Modify: GeoIP 调用点(`OverviewStats` 的 countriesReached/destinationCountries、Map 富化、Connections 行国旗)——统一在查询前 `guard !FakeIPClassifier(...).isSynthetic(addr)`。
- Test: 对应单元测试追加 fake-IP → 无国家。

- [ ] **Step 1–4:** 写失败测试(fake-IP 不产生国家)、实现守卫、跑绿。学习到的池前缀(如 198.0/16)从"已有域名映射的地址"喂入分类器(由 1.1 的重建流域名表派生)。
- [ ] **Step 5: commit** `-m "fix(geoip): do not geolocate synthetic fake-IP destinations"`。

### Task 1.5: code-reviewer gate(Phase 1) + 全量回归

- [ ] `feature-dev:code-reviewer` 审 Phase 1 diff(并发安全、双算、缝合正确性)。
- [ ] 全量回归:`swift test` 全绿;`scripts/smoke.sh` 正签启动开 Loon 实测——Connections 里经代理连接显示**真实域名 + 非 0 字节**、Overview proxyShare 非 0%、Map 不再因 fake-IP 标错国家、无 TCC 弹窗。

---

## Phase 2 — 主动 geo 解析(默认开,仅代理+未知 geo)+ 设置/隐私文案

> **整个 Phase 2 由 Task 2.0 的 demo 结果闸门控制。** demo 不通过(DoH 拿不到真实 IP)→ 放弃 Phase 2,只保留 Phase 1 的纯被动可见性(域名/字节/app、geo 留白),并向用户汇报。

### Task 2.0: demo 闸门 — 验证 DoH 在 TUN 下能拿真实 IP(先于一切实现)

- [ ] **Step 1:** 开 Loon TUN,跑 scratchpad `doh-probe.swift`(URLSession DoH,代表 app 内行为):`swift /private/tmp/.../scratchpad/doh-probe.swift www.cloudflare.com`。
- [ ] **Step 2:** 对照明文:`dig +short www.cloudflare.com @1.1.1.1`(预期被劫持成 fake)。
- [ ] **Step 3 判定:** DoH 输出真实公网 IP(非 fake 段)→ **采用**,进 2.1;若 DoH 也被劫持/失败 → **放弃 Phase 2,汇报用户**,只交付 Phase 1。
- [ ] **Step 4:** 若可行,把验证可用的 DoH 端点/参数记入 spec §10。

### Task 2.1: ActiveGeoResolver(协议 + 实现,纯核心可测)

**Files:**
- Create: `Sources/MatrixNetGeoIP/ActiveGeoResolver.swift`
- Test: `Tests/MatrixNetGeoIPTests/ActiveGeoResolverTests.swift`

**Interfaces:**
- Produces: `protocol DomainResolving: Sendable { func resolve(_ domain: String) async -> IPAddress? }`;`actor ActiveGeoResolver { init(enabled: Bool, resolver: DomainResolving, geo: GeoIPDatabase, ...); func country(forProxiedDomain domain: String) async -> String? }`。**默认 enabled = true**;`enabled == false` → 直接返回 nil 且**不调用** resolver;缓存 + 限流;仅对调用方传入的"代理+未知 geo"域名触发。

- [ ] **Step 1: 写失败测试** — 注入 mock `DomainResolving`:① enabled=false → `country(...)==nil` 且 mock 调用 0 次;② enabled=true → 解析→GeoIP→国家,mock 调用 1 次;③ 同域名二次调用走缓存(mock 仍 1 次)。
- [ ] **Step 2–4:** 实现(测试用 mock `DomainResolving`;真实实现**仅 DoH**:URLSession 请求 `https://1.1.1.1/dns-query`(IP 字面量,避免 bootstrap 被劫持),解析 `application/dns-json` 的 Answer→A 记录;**不得用明文 DNS/UDP**,见 Task 2.0 与 spec §5 后果2)。跑绿。
- [ ] **Step 5: commit** `-m "feat(geoip): opt-in active resolver for proxied-flow geolocation"`。

### Task 2.2: 接入 + 排除自身解析查询出抓包统计

- [ ] 在 GeoIP 富化链路接 `ActiveGeoResolver`,仅对"代理流且 `FakeIPClassifier` 命中/geo 未知"的域名触发;结果在 UI 标 `*`(来源=主动解析)。
- [ ] **自噪声防护测试**:解析器自身发起的 DNS 查询(可按目标解析器 IP/端口 或专用标记识别)**不计入** Connections/Usage/proxyShare。写失败测试 → 实现过滤 → 绿。
- [ ] commit `-m "feat(geoip): wire active resolver; exclude self DNS from stats"`。

### Task 2.3: 设置开关(默认开)+ 首启告知 + 隐私文案 + 8 语言

**Files:**
- Modify: `App/Sources/...Settings`(新增"代理流量主动解析国家"开关,**默认 ON**)+ 首启一次性说明。
- Modify: 8 语言 `.strings`/`.xcstrings`(en 源 + de/es/fr/ja/ko/zh-Hans/zh-Hant)。

- [ ] 实现开关(持久化,默认 true)、首启 disclosure、`*` 来源说明文案;补全 8 语言串(CI 强制覆盖)。
- [ ] commit `-m "feat(settings): proxy geo resolution toggle (default on) + disclosure, 8 langs"`。

### Task 2.4: code-reviewer gate(Phase 2)

- [ ] 审隐私/默认值正确(默认开但非代理零触发)、自噪声过滤、并发。

---

## Phase 3 — 全量回归 + 文档 + 发版 1.8.0

### Task 3.1: 版本号

- [ ] 改 `project.yml`:`settings.base` MARKETING_VERSION `1.8.0`/CURRENT_PROJECT_VERSION `39`;App `info.properties` CFBundleShortVersionString `1.8.0`/CFBundleVersion `39`;Widget 同。commit `-m "release: bump to 1.8.0 (39)"`(待最后)。

### Task 3.2: 文档同步(英文公共文档)

- [ ] `CHANGELOG.md` 加 `## [1.8.0]`:Added 代理真实可见性(真实域名/字节/app、按字节 proxyShare、可选主动 geo 默认开);Fixed fake-IP 不再错算国家、代理连接不再显示 0 字节。
- [ ] `README.md` + 7 语言 README:Connection Monitoring/Privacy 段补"仅代理场景说明"那一句(保留被动招牌);诚实写明经远程节点真服务器 geo 的限制。
- [ ] `NOTICE`/DocC 如涉及解析器依赖则补。
- [ ] commit `-m "docs: document proxy visibility (1.8.0), 8 langs"`。

### Task 3.3: 全量回归(测试 + 产物 + 真机)

- [ ] `swift test` 全绿;`swiftlint --strict` + `swiftformat --lint` 净。
- [ ] bundle 验证:`scripts/smoke.sh` 正签启动,确认 geoip.dat/threatlist.dat/worldmap.dat 仍打进;开 Loon 实测代理可见性端到端;关解析开关验证退回纯被动(mock/抓包确认零外发)。
- [ ] 无 TCC 弹窗。

### Task 3.4: 发版

- [ ] 提交版本号(3.1);推 origin/main;触发 CI Release;验 appcast `sparkle:version=39`/`1.8.0`、DMG 挂载验 bundle;更新项目记忆([[proxy-tun-visibility]]、[[feature-roadmap-2026-06]] 标记 1.8.0 完成)。

---

## Self-Review

- **Spec 覆盖**:§5 geo 抉择→Phase 2;§6.1 FakeIPClassifier→0.1+1.4;§6.2 reconstructor→0.2;§6.3 缝合→0.3+1.0+1.1;§6.4 SNI/DNS 域名→0.2(SNI)+1.1(注:DNS fakeIP↔域名 兜底在 1.1/1.4 派生学习前缀,纯非 TLS 流的 DNS 兜底如需独立单元可在 1.1 内补 `recordHostname` 既有机制);§6.5 指标/守卫→1.3+1.4;§6.6 主动解析→2.x;§6.7 去重→1.2;诚实限制→3.2 文档 + NE 降级标注(在 1.1 对"utun 无 app 侧流"的情形加"代理可见性不可用"标注——补为 1.1 的一个子步骤)。
- **占位符扫描**:Phase 0 全为完整代码;Phase 1.1 的 actor 测试与 PacketCaptureModel 接线按既有风格落地(实现时核对 `AppIdentity` 与 PKTAP `dir` 字段精确名)。1.0 是必须的真机校核步骤,非占位。
- **类型一致**:`TunneledPacket`/`ReconstructedFlow`/`FlowKey`/`FakeIPClassifier.isSynthetic` 在各任务间一致。
- **缺口**:DNS 纯非 TLS 流的域名兜底、NE 降级标注 已在上面补入对应任务的子步骤。
