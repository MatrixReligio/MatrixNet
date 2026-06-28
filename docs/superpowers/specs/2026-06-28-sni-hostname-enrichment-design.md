# 功能 B:TLS SNI 精确域名(不解密)— 设计文档

> 状态:定稿(自主模式)。语言:本文件中文;所有面向用户/开源字符串、注释、DocC 用英文。

## 1. 目标
让连接 / 包 / 用量 / 地图显示 App **真正请求的主机名**:从 TLS ClientHello 的 **SNI**(不解密)与 **DNS 应答**(名→IP)中提取主机名,回填到现有的 IP→hostname 富集映射,并**优先于反向 DNS(PTR)**(PTR 常是 CDN 泛域名,不准)。

## 2. 现状(已探查)
- `TLSDissector.dissect` **已**从 ClientHello 解出 `serverName`(SNI),但 `PacketDissector.parseApplicationLayer` 只取 `.node`,**丢弃** serverName。
- `DNSDissector.dissect` 返回 `(node, DNSMessage)`,`message.answers: [DNSResourceRecord{name, ip?}]` —— 注释写明"exposed for connection hostname enrichment",但同样被丢弃。
- `FlowCorrelator.hostnamesByIP` + `recordHostname(_:for:)` / `hostname(for:)` 管道**已存在但无调用方**(死代码,本就为此准备)。
- `AppModel.publish` 当前富集 `connection.remoteHostname` 与 `resolvedHostnames` **只用反向 DNS**(`HostnameResolver.snapshot()`),不读 correlator 的 hostnamesByIP。

结论:B 不需要新解析能力,而是**接通这条已设计好的富集链路**,并确立 SNI/DNS > 反向 DNS 的优先级。

## 3. 设计

### 3.1 解析层(MatrixNetDissection,改)
- 新值类型 `public struct HostnameObservation: Sendable, Equatable { public let ip: IPAddress; public let name: String }`(放 `DissectionResult.swift`)。
- `DissectedPacket` 增 `public let hostnames: [HostnameObservation]`(默认 `[]`,旧 init 兼容)。
- `PacketDissector.parseApplicationLayer` 返回类型从 `DissectionNode?` 改为 `(node: DissectionNode, hostnames: [HostnameObservation])?`,内部:
  - DNS:对 `message.answers` 中每个 `ip != nil` 的记录产出 `HostnameObservation(ip: ip, name: record.name)`(规范化:去尾点、小写)。
  - TLS:若 `result.serverName` 非空,产出 `HostnameObservation(ip: destination, name: serverName)`(destination 由 `dissect` 传入 application 解析)。
  - HTTP:暂不(明文 Host 头价值低、且 80 端口少;留作后续)。
- `dissect()` 把 application 的 hostnames 收进 `DissectedPacket.hostnames`。需要把 `network.destination`(IPAddress)传入 `parseApplicationLayer`。
- 主机名规范化纯函数 `HostnameNormalizer.normalize(_:) -> String?`(去尾点、转小写、空/根 `.` → nil),TDD。

### 3.2 采集接入(MatrixNetCapture + App)
- `ConnectionAggregator`:新增 `public func hostnameSnapshot() -> [IPAddress: String]`,转发 `correlator` 的全量映射(FlowCorrelator 增 `func allHostnames() -> [IPAddress: String]`)。`recordHostname` 已有,沿用。
- `PacketCaptureModel`:在拿到 `dissected` 后,对 `dissected.hostnames` 每项 `await aggregator.recordHostname(obs.name, for: obs.ip)`(激活管道)。

### 3.3 富集优先级(AppModel,改)
- refresh loop 取 `let observed = await aggregator.hostnameSnapshot()`,传入 `publish`。
- `publish` 富集时**优先级**:`observed[ip]`(SNI/DNS)> 反向 DNS(`resolver` snapshot)。即:
  - `connection.remoteHostname`:若 observed 有则用 observed,否则反向 DNS。
  - `resolvedHostnames[ip]`:同样 observed 优先。
- `showDomains` 开关与显示逻辑不变(B 只改"域名来源更准")。

## 4. 数据流
包 → `PacketDissector` 解出 SNI/DNS 名 → `DissectedPacket.hostnames` → `PacketCaptureModel` → `aggregator.recordHostname` → `correlator.hostnamesByIP` → `aggregator.hostnameSnapshot()` → `AppModel.publish`(observed 优先于反向 DNS)→ 连接/包/用量/地图显示精确域名。

## 5. 错误处理与边界
- SNI per-IP 覆盖:一个 IP(CDN)可能承载多 SNI,correlator 按 IP 存"最后写入",会丢失同 IP 不同 SNI 的逐流精度——v1 接受(仍远胜 PTR);真正逐流 SNI 需按连接键存,留作后续。
- 规范化:SNI/DNS 名去尾点、小写;空或纯 `.` 丢弃。
- 解析健壮性:沿用现有"任何畸形输入 best-effort、不抛不崩"(`try?` 链);hostnames 提取失败只是空数组。
- 不解密、不 MITM、不联网:SNI/DNS 均来自已捕获明文包。

## 6. 测试(TDD,先红后绿)
- `HostnameNormalizerTests`(MatrixNetModel 或 Dissection):去尾点、小写、空/根→nil。
- `PacketDissectorTests`(MatrixNetDissection):
  - 合成 DNS 响应包 → `dissected.hostnames` 含 (应答IP, 查询名)。
  - 合成 TLS ClientHello 包 → `dissected.hostnames` 含 (目的IP, SNI)。
  - 普通 TCP 包 → hostnames 空。
  (复用现有 dissection 测试里的 TLS/DNS 字节夹具;无则按 RFC 构造最小字节。)
- `ConnectionAggregator`:`recordHostname` 后 `hostnameSnapshot()[ip] == name`;`reset()` 清空。
- `FlowCorrelator`:`allHostnames()` 返回全部映射。
- AppModel 富集优先级:纯函数化"observed 优先于反向 DNS"的合并逻辑以便单测(抽 `HostnameMerge.preferred(observed:reverse:)` 或在 publish 内联+靠 aggregator/resolver 测覆盖)。

## 7. 本地化与开源文档
- 预计**无新 UI 字符串**(只改域名来源);若包详情新增"Server Name (SNI)"等可见标签,补 8 语言。
- README 功能列表的 DNS/域名条目更新为"SNI + DNS 富集";CHANGELOG 加 0.1.23 条目。

## 8. 发版:0.1.23 / build 24,流程同 A。

## 9. 阶段 review 关:设计→[review]→计划→[review]→实现→[code-reviewer]→测试→[review]→文档/本地化→[review]→发版→[appcast+本地验证]。
