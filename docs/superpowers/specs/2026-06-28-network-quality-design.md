# 功能 ③ 设计:per-app 网络质量诊断("为什么这个 App 慢")

> 本批第 3 个子项目。内部设计文档(中文)。目标版本:**1.4.0(build 34)**。

## 1. 目标与价值

被动地从抓到的包(PKTAP,带微秒时间戳)算出**每条连接/每个应用的网络质量**,回答"为什么这个 App 慢"——把卡顿归因到**本地网络** vs **服务端**:

- **握手 RTT** = SYN → SYN-ACK 的时间差(端点测到的是完整 client↔server 路径 RTT;Wireshark 称 iRTT)。
- **重传 / 丢包迹象** = 同向重复/回退的序列号段计数(纯序列号判定,无需解密)。
- **TLS/连接建立时长** = SYN → 首个 application_data(或首字节)。
- **TTFB 分解(尽力)** = TCP connect(SYN→SYN-ACK)+ 握手 + 服务端思考时间(请求发出→首字节返回的包间时序)。

竞品空白:Wireshark 能手动算但无 per-app、无 dashboard、无"为什么慢"叙事;Little Snitch 官方说其 pcap 是伪造头不能 debug 丢包;networkQuality/nettop 非 per-app/非持续。**没有 per-app 被动质量诊断工具。** 最贴近大众痛点,数据已在手(本就在抓包)。

## 2. 范围与边界

- **capture-only**:握手 RTT/重传需逐包时序与序列号,**只能来自 PKTAP**(NStat 无逐包时序)→ 与 JA4/QUIC 同源,未开抓包时无数据(优雅空态)。
- 本版:**TCP** 质量(握手 RTT、重传计数、连接建立时长)。UDP/QUIC 的 RTT(spin bit 不可靠)留后续;TTFB 的"服务端思考时间"作尽力估计(有明文请求边界时)。
- 不做主动探测(不发包);纯被动。

## 3. 架构与组件(纯核心 spike-first,复用现有管道)

数据流(抓包开启时):
```
PKTAP → PacketCaptureModel:每包已有 timestamp(微秒)+ direction + dissected
   → DissectedPacket 新增 tcpSegment:TCPSegment{flags,seq,ack,payloadLength}(从 TCP 层结构化透出)
   → ConnectionAggregator.recordTCP(flowKey, pid, timestampMicros, inbound, segment)
   → FlowQualityTracker(纯)按流累积 → FlowQuality{handshakeRTTms?, retransmits, setupMs?, ...}
   → qualitySnapshot() per-app/per-flow → AppModel(节流)→ 连接检查器 "Quality" 区
```

### 3.1 纯核心(MatrixNetDissection / MatrixNetModel,`swift test` 独立验证)
- **`TCPSegment`**(新,MatrixNetModel 或 Dissection):`flags:TCPFlags`(SYN/ACK/FIN/RST…)、`seq:UInt32`、`ack:UInt32`、`payloadLength:Int`。TCPDissector 已解这些字段(目前只产出 DissectionField 字符串)→ 增结构化产出,`DissectedPacket.tcpSegment: TCPSegment?`。
- **`FlowQualityTracker`**(新,纯,MatrixNetModel):`mutating func ingest(timestampMicros:UInt64, inbound:Bool, segment:TCPSegment)`;状态机:出向 SYN(无 ACK)记 synTs;入向 SYN-ACK 记 → handshakeRTT = synAckTs−synTs;重传 = 出向数据段 seq < 已见最大 seq(回退/重复,wraparound-aware)计数;setup = SYN→首个出向 payload。产出 `FlowQuality{handshakeRTTms:Double?, retransmits:Int, outOfOrder:Int, setupMs:Double?}`。纯、完全可 TDD(合成包序列)。
- **`FlowQuality`**(新,纯,Sendable,Equatable)。

### 3.2 归属与快照(MatrixNetCapture)
- `ConnectionAggregator` 增 `qualityByFlow: [FlowKey: FlowQualityTracker]`;`recordTCP(...)` 喂 tracker;`qualitySnapshot() -> [AppFlowQuality{app, address, quality}]`(per-app 归并取代表/最差值)。reset 清除。与 JA4/usage 记录同链。
- `PacketCaptureModel.attribute`:对有 `tcpSegment` 的行调 `recordTCP`(沿 ① 已建的 detached 归属任务)。

### 3.3 UI
- **连接检查器**新增 "Quality / 网络质量" 区:握手 RTT(ms)、重传次数、连接建立时长;无数据(未抓包/非 TCP)→ 空态引导(同 ① 指纹区)。
- (可选)Overview 不加 KPI 本版,聚焦连接级。

## 4. 错误处理与降级
- 非 TCP / 无 SYN 观测(连接在抓包前已建立)→ handshakeRTT 为 nil(显示"—"),重传仍可计。
- 抓包未开 → 无 tcpSegment → 无质量数据 → 空态。
- 序列号 wraparound 用 `Int32(bitPattern: a &- b)` 符号比较(同 StreamReassembler)。

## 5. 测试策略(TDD)
### 第 0 阶段:FlowQualityTracker 纯核心 spike(`swift test`,不动 app)
- 合成序列:出向 SYN@t0 → 入向 SYN-ACK@t0+20ms → 断言 handshakeRTTms≈20。
- 重传:出向 data seq=1000 然后 seq=1000(重复)→ retransmits=1;乱序回退计数。
- setup:SYN→首出向 payload 时间。
- 无 SYN(中途接入)→ handshakeRTT nil、重传仍计。
- wraparound 边界。
- `TCPSegment` 从 TCPDissector 结构化产出:构造 TCP 包断言 flags/seq/ack/payloadLength。
### 接入阶段(影响版本)
- `ConnectionAggregator.recordTCP`/`qualitySnapshot` per-app 归并;`PacketCaptureModel` 接线;连接检查器渲染 + 空态;回归 TCP/TLS/QUIC 不受影响。
- 全程 Swift Testing、零警告、双 linter、8 语言、界面核验。

## 6. 交付与发版
spike 绿 + review → 接入 → code-reviewer 清零 → 测试全绿 + 界面核验 → 文档(README ×8 "per-app 被动网络质量诊断" bullet、CHANGELOG、DocC、新 UI 串 8 语言)→ 版本 1.4.0/34 → 提交(无 Claude 署名)→ push → Release v1.4.0 → appcast(sparkle:version=34)→ 本地 Developer-ID 安装。

## 7. 自审清单
- 无 TBD;范围单一(TCP 被动质量,UDP/QUIC RTT 留后续)。
- 复用:TCP 字段来自既有 TCPDissector(结构化化),归属/持久化走 ① 管道;wraparound 同 StreamReassembler 手法。
- capture-only 边界明确;命名一致:`TCPSegment`/`TCPFlags`/`FlowQualityTracker`/`FlowQuality`/`recordTCP`/`qualitySnapshot`/`AppFlowQuality`。
